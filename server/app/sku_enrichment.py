"""Add only verified detail-page SKUs to existing products, in bounded batches."""
import logging
import re
from bs4 import BeautifulSoup
from sqlalchemy import select, text
from .db import session, engine
from .models import Product
from .catalog import writer, upsert
from .sku_diagnostics import missing_sku, blank_sku

log = logging.getLogger('linella')


def detail_sku(source, source_id):
    if not re.fullmatch(r'[0-9]+', source_id):
        raise ValueError('Invalid source product ID')
    doc = BeautifulSoup(source, 'lxml')
    if doc.select_one('.ty-age-verification__txt, .ty-age-verification__block'):
        return None
    # Exact ID binds the SKU to the requested product, not a recommendation.
    identities = doc.select(f'input[name="product_data[{source_id}][product_id]"]')
    if not identities or any(n.get('value') != source_id for n in identities):
        raise ValueError('Detail product identity not confirmed')
    values = {n.get_text(strip=True) for n in doc.select(
        f'[id="product_code_{source_id}"] .ut2--sku-text')}
    values.discard('')
    if not values:
        return None
    if len(values) != 1:
        raise ValueError('Conflicting source SKU values')
    value = values.pop()
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._/-]{0,127}', value):
        raise ValueError('Invalid source SKU')
    return value  # Text: do not drop leading zeros or infer from product_id.


async def enrich_skus(fetcher, limit=100, after=''):
    if not 1 <= limit <= 1000:
        raise ValueError('SKU batch limit must be between 1 and 1000')
    counts = dict(checked=0, added=0, unchanged=0, unavailable=0, conflicts=0, errors=0, after=after)
    with engine().connect().execution_options(isolation_level='AUTOCOMMIT') as lock:
        if not lock.scalar(text('SELECT pg_try_advisory_lock(37012026)')):
            raise RuntimeError('Another catalog sync is running')
        try:
            with session() as db:
                if after and db.get(Product, after) is None:
                    raise ValueError('Unknown after product ID; use the exact previous result or an empty cursor')
                products = db.scalars(select(Product).where(missing_sku(), Product.id > after)
                                      .order_by(Product.id).limit(limit)).all()
            for p in products:
                counts['checked'] += 1
                counts['after'] = p.id
                try:
                    sku = detail_sku(await fetcher.get(p.product_url), p.source_product_id)
                    if sku is None:
                        counts['unavailable'] += 1
                        continue
                    with session() as db, writer(db) as state:
                        current = db.get(Product, p.id)
                        if current is None or current.source_product_id != p.source_product_id:
                            raise ValueError('Product identity changed during enrichment')
                        other = db.scalar(select(Product.id).where(Product.sku == sku, Product.id != p.id))
                        if other or (not blank_sku(current.sku) and current.sku != sku):
                            counts['conflicts'] += 1
                            log.warning('SKU conflict for existing product %s; identifiers preserved', p.id)
                            continue
                        result = upsert(db, state, Product, dict(id=p.id, sku=sku), 'product')
                        counts['unchanged' if result == 'unchanged' else 'added'] += 1
                except Exception as exc:
                    counts['errors'] += 1
                    log.warning('SKU enrichment failed for %s (%s); previous data preserved', p.id, type(exc).__name__)
            return counts
        finally:
            lock.execute(text('SELECT pg_advisory_unlock(37012026)'))
