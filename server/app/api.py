import base64
import hashlib
import hmac
import json
import os
from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.gzip import GZipMiddleware
from sqlalchemy import select, text, func, case, cast, String
from .db import session
from .models import CatalogState, ProductChange, Product, Category, Promotion, SpecialCollection
from .catalog import payload

app = FastAPI(title='Caută Preț', version='2.0.0')
app.add_middleware(GZipMiddleware, minimum_size=1000)


def secret():
    value = os.environ.get('SYNC_CURSOR_SECRET', '')
    if len(value) < 32:
        raise RuntimeError('Set SYNC_CURSOR_SECRET to at least 32 random characters')
    return value.encode()


def token(data):
    raw = base64.urlsafe_b64encode(json.dumps(data, separators=(',', ':')).encode()).decode().rstrip('=')
    return raw + '.' + hmac.new(secret(), raw.encode(), hashlib.sha256).hexdigest()


def decode(value):
    try:
        raw, signature = value.split('.')
        if not hmac.compare_digest(signature, hmac.new(secret(), raw.encode(), hashlib.sha256).hexdigest()):
            raise ValueError()
        return json.loads(base64.urlsafe_b64decode(raw + '=' * (-len(raw) % 4)))
    except (ValueError, TypeError, KeyError):
        raise HTTPException(400, 'Invalid cursor')


@app.get('/api/v1/health')
def health():
    try:
        secret()
        with session() as db:
            db.execute(text('SELECT 1'))
            state = db.get(CatalogState, 1)
            return dict(status='ok', database='postgresql', serverVersion=state.version if state else 0)
    except Exception:
        raise HTTPException(503, 'Database or configuration unavailable')


def sync_page(mode, since, cursor, generation, limit):
    with session() as db:
        state = db.get(CatalogState, 1)
        if state is None:
            raise HTTPException(503, 'Run migrations and initial sync first')
        if generation and generation != state.generation:
            raise HTTPException(409, 'Catalog generation changed; bootstrap required')
        bounds = decode(cursor) if cursor else dict(mode=mode, since=since, until=state.version,
                                                   generation=state.generation, after='' if mode == 'bootstrap' else since)
        if bounds['generation'] != state.generation:
            raise HTTPException(409, 'Catalog generation changed; bootstrap required')
        if bounds['mode'] != mode or bounds['since'] != since or bounds['until'] > state.version or since > bounds['until']:
            raise HTTPException(400, 'Inconsistent sync cursor')
        c = ProductChange
        if mode == 'bootstrap':
            latest = select(c, func.row_number().over(partition_by=(c.kind, c.entity_id),
                            order_by=c.version.desc()).label('rn')).where(c.version <= bounds['until']).subquery()
            rank = case((latest.c.kind == 'category', '0'), (latest.c.kind == 'product', '1'),
                        (latest.c.kind == 'promotion', '2'), (latest.c.kind == 'collection', '3'), else_='4')
            depth = case((latest.c.kind == 'category', func.lpad(latest.c.payload['level'].astext, 5, '0')), else_='00000')
            key = func.concat(rank, ':', depth, ':', latest.c.entity_id)
            rows = db.execute(select(latest.c.kind, latest.c.entity_id, latest.c.payload, key.label('key'))
                    .where(latest.c.rn == 1, key > bounds['after']).order_by(key).limit(limit + 1)).mappings().all()
        else:
            rows = db.execute(select(c.kind, c.entity_id, c.payload, c.version.label('key'))
                    .where(c.version > bounds['after'], c.version <= bounds['until'])
                    .order_by(c.version).limit(limit + 1)).mappings().all()
        more, page = len(rows) > limit, rows[:limit]
        next_cursor = token({**bounds, 'after': page[-1]['key']}) if more else None
        return dict(generation=state.generation, serverVersion=bounds['until'], nextCursor=next_cursor,
                    changes=[dict(kind=r['kind'], id=r['entity_id'], data=r['payload']) for r in page])


@app.get('/api/v1/catalog/bootstrap')
def bootstrap(cursor: str | None = None, limit: int = Query(250, ge=1, le=500)):
    return sync_page('bootstrap', 0, cursor, None, limit)


@app.get('/api/v1/sync')
def sync(since: int = Query(0, ge=0), generation: str | None = None,
         cursor: str | None = None, limit: int = Query(250, ge=1, le=500)):
    return sync_page('delta', since, cursor, generation, limit)


@app.get('/api/v1/products')
def products(after: str = '', limit: int = Query(100, ge=1, le=500)):
    with session() as db:
        rows = db.scalars(select(Product).where(Product.id > after).order_by(Product.id).limit(limit+1)).all()
        return dict(items=[payload(r) for r in rows[:limit]], nextCursor=rows[limit-1].id if len(rows)>limit else None)


@app.get('/api/v1/products/{product_id}')
def product(product_id: str):
    with session() as db:
        row = db.get(Product, product_id)
        if not row: raise HTTPException(404, 'Product not found')
        return payload(row)


def documents(model, after, limit):
    with session() as db:
        rows = db.scalars(select(model).where(model.id > after).order_by(model.id).limit(limit+1)).all()
        return dict(items=[({**r.data, 'id': r.id, 'version': r.version} if hasattr(r, 'data') else payload(r))
                           for r in rows[:limit]], nextCursor=rows[limit-1].id if len(rows)>limit else None)


@app.get('/api/v1/categories')
def categories(after: str = '', limit: int = Query(250, ge=1, le=500)):
    return documents(Category, after, limit)


@app.get('/api/v1/promotions')
def promotions(after: str = '', limit: int = Query(100, ge=1, le=500)):
    return documents(Promotion, after, limit)


@app.get('/api/v1/special-collections')
def collections(after: str = '', limit: int = Query(100, ge=1, le=500)):
    return documents(SpecialCollection, after, limit)
