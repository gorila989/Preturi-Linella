import asyncio
import logging
import os
import time
from datetime import datetime, timezone
import httpx
from sqlalchemy import select, delete, text
from .db import session, engine
from .models import (Category, Product, Promotion, SpecialCollection, SpecialCollectionProduct,
                     ProductPromotion, SyncRun, now)
from .catalog import writer, upsert, put_document
from .parser import BASE, public_url, parse_categories, parse_products, parse_promotion, next_page

log = logging.getLogger('linella')


class Fetcher:
    def __init__(self, client=None):
        self.client = client or httpx.AsyncClient(timeout=30, follow_redirects=False,
            headers={'User-Agent': os.getenv('SCRAPER_USER_AGENT', 'CautaPretCatalog/2.0')})
        self.sem = asyncio.Semaphore(max(1, min(4, int(os.getenv('SCRAPER_CONCURRENCY', '4')))))
        self.rate_lock = asyncio.Lock()
        self.next_at = 0.0
        self.requests = 0

    async def get(self, url):
        return await self.request('GET', url)

    async def request(self, method, url, data=None, on_request=None):
        public_url(url)
        async with self.sem:
            for attempt in range(3):
                try:
                    async with self.rate_lock:
                        await asyncio.sleep(max(0, self.next_at - time.monotonic()))
                        self.next_at = time.monotonic() + max(.25, float(os.getenv('SCRAPER_INTERVAL_SECONDS', '.5')))
                    self.requests += 1
                    if on_request:
                        on_request()
                    async with self.client.stream(method, url, data=data,
                            headers={'X-Requested-With': 'XMLHttpRequest'} if method == 'POST' else None) as response:
                        response.raise_for_status()
                        body_bytes = bytearray()
                        async for chunk in response.aiter_bytes():
                            body_bytes.extend(chunk)
                            if len(body_bytes) > 8 * 1024 * 1024:
                                raise ValueError('Source page exceeds 8 MiB')
                        return body_bytes.decode('utf-8')
                except (httpx.HTTPError, UnicodeError) as exc:
                    if isinstance(exc, httpx.HTTPStatusError) and exc.response.status_code not in (408, 429, 500, 502, 503, 504):
                        raise
                    if attempt == 2: raise
                    log.warning('Retry %s (%s)', url, type(exc).__name__)
                    delay = 2 ** attempt
                    if isinstance(exc, httpx.HTTPStatusError) and exc.response.status_code == 429:
                        try:
                            delay = max(delay, min(30, float(exc.response.headers.get('Retry-After', '0'))))
                        except ValueError:
                            pass
                    await asyncio.sleep(delay)

    async def close(self):
        await self.client.aclose()


class Synchronizer:
    def __init__(self, fetcher):
        self.fetcher = fetcher
        self.categories = []
        self.enrich_sku = False  # Enabled by run(); standalone parsing scopes keep their contract.
        self.sku_attempted = set()
        self.stats = dict(categoriesProcessed=0, pagesDownloaded=0, productDetailPagesDownloaded=0,
                          categoryPagesDownloaded=0,
                          productsParsed=0, productsAdded=0, productsUpdated=0, productsUnchanged=0,
                          promotionsDetected=0, imagesProcessed=0, errors=0,
                          ageRestrictedPages=0, ageRestrictedCards=0)
        from .search_client import search_metrics
        self.stats.update(search_metrics())
        self.stats.update(skusExtracted=0, skuUnavailable=0, skuErrors=0, skuConflicts=0)

    async def complete_skus(self, items):
        if not self.enrich_sku:
            return
        from .sku_enrichment import detail_sku
        with session() as db:
            existing = {p.source_product_id: p.sku for p in db.scalars(select(Product).where(
                Product.source_product_id.in_([p['source_product_id'] for p in items])))}
        async def one(item):
            sid = item['source_product_id']
            if item.get('sku') or existing.get(sid) or sid in self.sku_attempted:
                return
            self.sku_attempted.add(sid)
            self.stats['productDetailPagesDownloaded'] += 1
            try:
                sku = detail_sku(await self.fetcher.get(item['product_url']), sid)
                if sku:
                    item['sku'] = sku
                    self.stats['skusExtracted'] += 1
                else:
                    self.stats['skuUnavailable'] += 1
            except Exception as exc:
                self.stats['skuErrors'] += 1
                log.warning('SKU unavailable for %s (%s); catalog data preserved', sid, type(exc).__name__)
        # At most one listing page in memory; shared Fetcher enforces concurrency/rate.
        await asyncio.gather(*(one(item) for item in items))

    def protect_sku(self, db, item):
        sku = item.get('sku')
        if not sku:
            return
        current = db.get(Product, item['id'])
        other = db.scalar(select(Product.id).where(Product.sku == sku, Product.id != item['id']))
        if other or (current is not None and current.sku not in (None, sku)):
            item.pop('sku', None)
            self.stats['skuConflicts'] += 1
            log.warning('Conflicting SKU for %s; existing identifiers preserved', item['id'])

    def category_for(self, url):
        matches = [c for c in self.categories if url.startswith(c['source_url'])]
        return max(matches, key=lambda c: len(c['source_url']))['id'] if matches else None

    async def scope(self, url, category=None, collection=None, first=None, only_ids=None):
        visited, seen, signatures = set(), set(), set()
        promotion = None
        restricted_scope = False
        while url:
            if url in visited: raise ValueError('Pagination loop; scope not confirmed complete')
            visited.add(url)
            source = first if first is not None else await self.fetcher.get(url)
            first = None
            if collection == 'mega' and promotion is None:
                promotion = parse_promotion(source)
            items, counts = parse_products(source, category)
            if counts['ageRestrictedPage'] or counts['ageRestrictedCards']:
                restricted_scope = True
                self.stats['ageRestrictedPages'] += 1
                self.stats['ageRestrictedCards'] += counts['ageRestrictedCards']
                log.warning('Age verification required at %s; importing visible products only; scope remains incomplete', url)
            signature = tuple(sorted(p['id'] for p in items))
            if signature and signature in signatures:
                raise ValueError('Repeated page content; scope not confirmed complete')
            signatures.add(signature)
            log.info('page %s %s', url, counts)
            self.stats['pagesDownloaded'] += 1
            self.stats['categoryPagesDownloaded'] += 1
            self.stats['productsParsed'] += len(items)
            self.stats['imagesProcessed'] += sum(p['thumbnail_url'] is not None for p in items)
            self.stats['promotionsDetected'] += counts['promotionalProductsDetected']
            await self.complete_skus([item for item in items if only_ids is None or item['source_product_id'] in only_ids])
            with session() as db, writer(db) as state:
                existing_by_source = {p.source_product_id: p for p in db.scalars(select(Product).where(
                    Product.source_product_id.in_([item['source_product_id'] for item in items])))}
                for item in items:
                    if only_ids is not None and item['source_product_id'] not in only_ids:
                        continue
                    existing = existing_by_source.get(item['source_product_id'])
                    if existing is not None:
                        item['id'] = existing.id
                    if only_ids is not None and existing is not None and (existing.promotion_start or existing.promotion_end):
                        # A category page is not authoritative for campaign dates.
                        for key in ('price', 'old_price', 'promo_price', 'discount_percent',
                                    'promotion_state', 'promotion_start', 'promotion_end'):
                            item.pop(key, None)
                    item['category_id'] = self.category_for(item['product_url']) or category
                    # On category cards an unknown end date is a current observation.
                    # On Mega cards a known interval is retained and evaluated by the phone.
                    if promotion and item['promotion_state'] == 'observed':
                        item.update(promotion_state='dated', promotion_start=promotion['startDateTime'],
                                    promotion_end=promotion['endDateTime'])
                    self.protect_sku(db, item)
                    result = upsert(db, state, Product, item, 'product')
                    self.stats['products' + result.title()] += 1
                    seen.add(item['id'])
            url = None if counts['ageRestrictedPage'] else next_page(source, url)
        if restricted_scope or only_ids is not None:
            # Visible rows are saved, but missing rows are not confirmed absent.
            # Preserve existing collection membership and inactivity counters.
            return seen
        if collection:
            with session() as db, writer(db) as state:
                data = dict(type=collection, name='Mega Ofertă' if collection == 'mega' else 'Cele mai bune oferte',
                            productIds=sorted(seen), startDateTime=promotion['startDateTime'] if promotion else None,
                            endDateTime=promotion['endDateTime'] if promotion else None)
                put_document(db, state, SpecialCollection, 'collection', collection, data)
                db.execute(delete(SpecialCollectionProduct).where(SpecialCollectionProduct.collection_id == collection))
                db.add_all([SpecialCollectionProduct(collection_id=collection, product_id=p) for p in seen])
                if promotion:
                    put_document(db, state, Promotion, 'promotion', promotion['id'], {**promotion, 'productIds': sorted(seen)})
                    db.execute(delete(ProductPromotion).where(ProductPromotion.promotion_id == promotion['id']))
                    db.add_all([ProductPromotion(promotion_id=promotion['id'], product_id=p) for p in seen])
        if category and seen:
            # Only a successfully exhausted, non-empty scope may advance absences.
            # Use batches so even a 50k catalog is never materialized as ORM objects.
            ids = [c['id'] for c in self.categories if c['source_url'].startswith(BASE.rstrip('/') + category)]
            after = ''
            while True:
                with session() as db, writer(db) as state:
                    rows = db.scalars(select(Product).where(Product.category_id.in_(ids or [category]), Product.id > after)
                                      .order_by(Product.id).limit(250)).all()
                    for p in rows:
                        if p.id not in seen:
                            upsert(db, state, Product, dict(id=p.id, missing_count=p.missing_count+1,
                                possibly_inactive=True, inactive=p.missing_count+1 >= 3), 'product')
                    if not rows: break
                    after = rows[-1].id
        return seen

    async def run(self, selection=None):
        self.enrich_sku = True
        started = time.monotonic()
        # Session advisory locks survive statement commits. Keep this dedicated
        # connection out of a transaction while HTTP requests and page writes run;
        # otherwise hosted Postgres can terminate it as idle-in-transaction.
        with engine().connect().execution_options(isolation_level='AUTOCOMMIT') as lock:
            if not lock.scalar(text('SELECT pg_try_advisory_lock(37012026)')):
                raise RuntimeError('Another catalog sync is running')
            try:
                with session() as db, db.begin():
                    # The advisory lock proves no prior worker still owns a run.
                    for interrupted in db.scalars(select(SyncRun).where(SyncRun.status == 'running')):
                        interrupted.status, interrupted.finished_at = 'interrupted', now()
                    run = SyncRun()
                    db.add(run)
                    db.flush()
                    run_id = run.id
                try:
                    if selection is not None:
                        from .data_source import LinellaDataSource
                        with session() as db:
                            self.categories = [dict(id=c.id, parent_id=c.parent_id, source_url=c.source_url) for c in db.scalars(select(Category))]
                        await LinellaDataSource(self).quick(**selection)
                        from .identifier_matching import reconcile_pending
                        reconcile_pending()
                        return
                    source = await self.fetcher.get(BASE+'toate-categoriile/')
                    self.categories = parse_categories(source)
                    with session() as db, writer(db) as state:
                        for c in self.categories: upsert(db, state, Category, c, 'category')
                    # Non-overlapping root scopes; the shared fetcher caps global concurrency.
                    gate = asyncio.Semaphore(4)
                    async def one(c):
                        async with gate:
                            try:
                                await self.scope(c['source_url'], category=c['id'])
                                self.stats['categoriesProcessed'] += 1
                            except Exception:
                                self.stats['errors'] += 1
                                log.exception('Category scope failed: %s', c['id'])
                    await asyncio.gather(*(one(c) for c in self.categories if c['parent_id'] is None))
                    from .data_source import LinellaDataSource, configured_selections
                    data_source = LinellaDataSource(self)
                    if data_source.enabled:
                        for selection in configured_selections():
                            try:
                                await data_source.quick(**selection)
                            except Exception:
                                self.stats['errors'] += 1
                                log.exception('Selective enrichment and fallback failed')
                    for name, route in [('best', 'oferte-avantajoase/'), ('mega', 'mega-oferta/')]:
                        try: await self.scope(BASE+route, collection=name)
                        except Exception:
                            self.stats['errors'] += 1
                            log.exception('Collection scope failed: %s', name)
                    from .identifier_matching import reconcile_pending
                    reconcile_pending()
                except Exception:
                    self.stats['errors'] += 1
                    raise
                finally:
                    self.stats.update(totalRequests=self.fetcher.requests, durationMs=int((time.monotonic()-started)*1000))
                    with session() as db, db.begin():
                        run = db.get(SyncRun, run_id)
                        run.finished_at, run.status, run.stats = now(), 'partial' if any(self.stats[k] for k in ('errors', 'ageRestrictedPages', 'searchPromotionConflicts', 'skuErrors', 'skuUnavailable', 'skuConflicts')) else 'complete', self.stats
                    if self.stats['ageRestrictedPages']:
                        log.warning('PARTIAL CATALOG: age-restricted content was not imported; previous memberships preserved')
                    log.info('SyncRun %s %s', run_id, {k: v for k, v in self.stats.items() if k != 'searchCommercialIndicators'})
            finally:
                lock.execute(text('SELECT pg_advisory_unlock(37012026)'))
