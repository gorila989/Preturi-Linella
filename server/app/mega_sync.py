"""Publish a complete Mega campaign atomically over existing catalog products."""
import json
import logging
import os
import re
import time
from datetime import datetime, timezone
from bs4 import BeautifulSoup
from sqlalchemy import select, delete
from . import mega_source
from .parser import BASE
from .sku_enrichment import detail_sku
from .sku_diagnostics import blank_sku
from .db import session
from .catalog import writer, upsert, put_document
from .models import Product, Promotion, ProductPromotion, SpecialCollection, SpecialCollectionProduct

log = logging.getLogger('linella')


def campaign_status(data, at):
    if at < datetime.fromisoformat(data['startDateTime']):
        return 'upcoming'
    return 'expired' if at > datetime.fromisoformat(data['endDateTime']) else 'active'


def mega_sku(source, sid):
    value = detail_sku(source, sid)
    if value:
        return value
    doc = BeautifulSoup(source, 'lxml')
    # Exact product wrapper avoids taking a recommendation's SKU.
    nodes = doc.select(f'[id="product_code_{sid}"] .ut2-sku-text')
    values = {n.get_text(strip=True) for n in nodes} - {''}
    if not values:
        return None
    if len(values) != 1 or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._/-]{0,127}', next(iter(values))):
        raise ValueError('Conflicting or invalid Mega detail SKU')
    return values.pop()


async def sync_mega(job):
    started = time.monotonic()
    metrics = dict(source_url=None, promotion_id=None, period_start=None, period_end=None,
        pages_checked=0, cards_seen=0, unique_products=0, existing_products=0, new_products=0,
        products_linked=0, products_unlinked=0, sku_existing=0, sku_fetched=0, sku_missing=0,
        sku_conflicts=0, price_normal_found=0, promo_price_found=0, discount_found=0,
        images_found=0, errors=0)
    try:
        campaign = mega_source.discover(await job.fetcher.get(BASE))
        metrics.update(source_url=campaign['sourceUrl'], period_start=campaign['startDate'],
                       period_end=campaign['endDate'])
        # Cards alone do not carry a form. Initialize the authorized official
        # session before walking a mixed listing, using the existing Fetcher.
        if os.getenv('LINELLA_AGE_CONFIRMED', '').lower() == 'true':
            await job.fetcher.get(BASE + 'alcool/')
        url = campaign['sourceUrl']
        visited, signatures, rows = set(), set(), {}
        while url:
            if url in visited:
                raise ValueError('Mega pagination loop; previous campaign preserved')
            visited.add(url)
            source = await job.fetcher.get(url)
            source_id = mega_source.promotion_id(source, url)
            if metrics['promotion_id'] is not None and source_id != metrics['promotion_id']:
                raise ValueError('Mega campaign changed during pagination')
            metrics['promotion_id'] = source_id
            items, counts, cards = mega_source.products(source)
            metrics['pages_checked'] += 1
            metrics['cards_seen'] += cards
            job.stats['pagesDownloaded'] += 1
            job.stats['categoryPagesDownloaded'] += 1
            job.stats['productsParsed'] += len(items)
            job.stats['imagesProcessed'] += sum(p['thumbnail_url'] is not None for p in items)
            job.stats['promotionsDetected'] += counts['promotionalProductsDetected']
            if counts['ageRestrictedPage'] or counts['ageRestrictedCards']:
                raise ValueError('Mega contains restricted products; previous campaign preserved')
            signature = tuple(sorted(item['source_product_id'] for item in items))
            if signature and signature in signatures:
                raise ValueError('Repeated Mega page; previous campaign preserved')
            signatures.add(signature)
            for item in items:
                sid = item['source_product_id']
                if sid in rows and rows[sid] != item:
                    raise ValueError('Conflicting duplicate Mega product')
                rows[sid] = item
            url = mega_source.campaign_next(source, url, campaign['sourceUrl'])
        if not rows:
            raise ValueError('Empty Mega campaign; previous data preserved')
        # Do not combine a period that changed mid-run with old product pages.
        if mega_source.discover(await job.fetcher.get(BASE)) != campaign:
            raise ValueError('Advertised Mega period changed during import; retry required')
        metrics['unique_products'] = len(rows)
        with session() as db:
            existing = {p.source_product_id: p.sku for p in db.scalars(select(Product).where(
                Product.source_product_id.in_(rows)))}
        for sid, item in rows.items():
            metrics['existing_products' if sid in existing else 'new_products'] += 1
            if not blank_sku(existing.get(sid)):
                item['sku'] = existing[sid]
                metrics['sku_existing'] += 1
            elif blank_sku(item.get('sku')):
                try:
                    job.stats['productDetailPagesDownloaded'] += 1
                    item['sku'] = mega_sku(await job.fetcher.get(item['product_url']), sid)
                    metrics['sku_fetched' if item['sku'] else 'sku_missing'] += 1
                    job.stats['skusExtracted' if item['sku'] else 'skuUnavailable'] += 1
                except Exception as exc:
                    metrics['sku_missing'] += 1
                    job.stats['skuErrors'] += 1
                    log.warning('Mega SKU unavailable for %s (%s); identifiers preserved', sid, type(exc).__name__)
            else:
                metrics['sku_fetched'] += 1
            metrics['price_normal_found'] += item['old_price'] is not None
            metrics['promo_price_found'] += item['promo_price'] is not None
            metrics['discount_found'] += (item['discount_percent'] or 0) > 0
            metrics['images_found'] += item['thumbnail_url'] is not None
        at = datetime.now(timezone.utc)
        campaign.update(sourcePromotionId=metrics['promotion_id'], status=campaign_status(campaign, at))
        with session() as db, writer(db) as state:
            current = db.get(SpecialCollection, 'mega')
            if current and current.data.get('startDateTime', '') > campaign['startDateTime']:
                raise ValueError('Older Mega source cannot replace a newer saved campaign')
            before = set(db.scalars(select(SpecialCollectionProduct.product_id).where(
                SpecialCollectionProduct.collection_id == 'mega')))
            existing_rows = {p.source_product_id: p for p in db.scalars(select(Product).where(
                Product.source_product_id.in_(rows)))}
            members = set()
            for sid, raw in rows.items():
                item = dict(raw)
                old = existing_rows.get(sid)
                if old:
                    item['id'] = old.id
                    # Mega must not reclassify or change catalog absence state.
                    for key in ('category_id', 'in_stock', 'possibly_inactive', 'inactive', 'missing_count'):
                        item.pop(key, None)
                    if not blank_sku(old.sku):
                        item['sku'] = old.sku
                    for key in ('thumbnail_url', 'source_image_url', 'full_image_url'):
                        if item.get(key) is None:
                            item.pop(key, None)
                else:
                    item['category_id'] = job.category_for(item['product_url'])
                if item.get('sku') and db.scalar(select(Product.id).where(
                        Product.sku == item['sku'], Product.id != item['id'])):
                    metrics['sku_conflicts'] += 1
                    job.stats['skuConflicts'] += 1
                    item.pop('sku', None)
                if item.get('price') is None and old:
                    for key in ('price', 'old_price', 'promo_price', 'discount_percent',
                                'promotion_state', 'promotion_start', 'promotion_end', 'quantity'):
                        item.pop(key, None)
                elif item['promotion_state'] == 'observed':
                    item.update(promotion_state='dated', promotion_start=campaign['startDateTime'],
                                promotion_end=campaign['endDateTime'])
                result = upsert(db, state, Product, item, 'product')
                job.stats['products' + result.title()] += 1
                members.add(item['id'])
            # Preserve old Promotion and ProductPromotion rows as history.
            for previous in db.scalars(select(Promotion).where(Promotion.id != campaign['id'])):
                if previous.data.get('type') == 'mega':
                    status = campaign_status(previous.data, at)
                    put_document(db, state, Promotion, 'promotion', previous.id,
                                 {**previous.data, 'status': 'historical' if status == 'active' else status})
            data = {**campaign, 'productIds': sorted(members)}
            put_document(db, state, Promotion, 'promotion', campaign['id'], data)
            linked = set(db.scalars(select(ProductPromotion.product_id).where(
                ProductPromotion.promotion_id == campaign['id'])))
            if linked - members:
                db.execute(delete(ProductPromotion).where(ProductPromotion.promotion_id == campaign['id'],
                                                          ProductPromotion.product_id.in_(linked - members)))
            db.add_all(ProductPromotion(promotion_id=campaign['id'], product_id=p) for p in members - linked)
            put_document(db, state, SpecialCollection, 'collection', 'mega', {**data, 'promotionId': campaign['id']})
            if before - members:
                db.execute(delete(SpecialCollectionProduct).where(SpecialCollectionProduct.collection_id == 'mega',
                    SpecialCollectionProduct.product_id.in_(before - members)))
            db.add_all(SpecialCollectionProduct(collection_id='mega', product_id=p) for p in members - before)
            metrics['products_linked'] = len(members)
            metrics['products_unlinked'] = len(before - members)
        return metrics
    except Exception:
        metrics['errors'] += 1
        raise
    finally:
        metrics['duration_seconds'] = round(time.monotonic() - started, 3)
        log.info('MEGA OFFER SYNC %s', json.dumps(metrics, ensure_ascii=True))
