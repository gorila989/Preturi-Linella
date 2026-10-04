"""Read-only catalog diagnostics. Never print connection strings or credentials."""
from sqlalchemy import select, func, or_, text
from .db import session
from .models import Product, CatalogState


def missing_sku():
    return or_(Product.sku.is_(None), Product.sku.op('~')(r'^\s*$'))


def blank_sku(value):
    return value is None or not value.strip()


def diagnose_skus(after=''):
    missing = missing_sku()
    count = func.count
    with session() as db:
        db.execute(text('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY'))
        row = db.execute(select(
            count().label('total_products'),
            count().filter(~missing).label('products_with_sku'),
            count().filter(missing).label('products_without_sku'),
            count().filter(Product.sku.is_(None)).label('products_with_null_sku'),
            count().filter(Product.sku == '').label('products_with_empty_sku'),
            count().filter(Product.sku != '', Product.sku.op('~')(r'^\s*$')).label('products_with_whitespace_sku'),
            count().filter(Product.sku.op('~')(r'^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$')).label('products_with_valid_sku'),
            count().filter(missing, Product.id > after).label('eligible_after'),
            count().filter(missing, Product.id <= after).label('excluded_by_after'),
        ).select_from(Product)).mappings().one()
        result = dict(database='connected', **dict(row), after=after)
        result['after_exists'] = not after or db.get(Product, after) is not None
        state = db.get(CatalogState, 1)
        result['catalog_generation'] = state.generation if state else None
        result['catalog_version'] = state.version if state else None
    result['reason'] = ('empty_catalog' if not result['total_products'] else
                        'all_products_have_sku' if not result['products_without_sku'] else
                        'invalid_after' if not result['after_exists'] else
                        'missing_products_before_cursor' if not result['eligible_after'] else
                        'ready')
    return result


def compare_render(result, url):
    import httpx
    # No credentials are sent. Compare catalog identity, not passwords/URLs.
    try:
        response = httpx.get(url.rstrip('/') + '/api/v1/catalog/bootstrap',
                             params={'limit': 1}, timeout=90)
        response.raise_for_status()
        generation = response.json().get('generation')
        result['render_catalog_matches'] = bool(generation and generation == result['catalog_generation'])
    except Exception:
        result['render_catalog_matches'] = 'unavailable'
    return result
