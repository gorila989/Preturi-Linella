from contextlib import contextmanager
from decimal import Decimal
from datetime import datetime
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from .models import CatalogState, Category, Product, ProductChange, now


def camel(name):
    first, *rest = name.split('_')
    return first + ''.join(x.title() for x in rest)


def payload(row):
    result = {}
    for col in row.__table__.columns:
        value = getattr(row, col.name)
        if isinstance(value, Decimal): value = float(value)
        if isinstance(value, datetime): value = value.isoformat()
        result[camel(col.name)] = value
    return result


@contextmanager
def writer(db):
    """Every publisher MUST use this lock, including imports and CLI changes."""
    with db.begin():
        db.execute(insert(CatalogState).values(id=1, version=0).on_conflict_do_nothing())
        state = db.scalar(select(CatalogState).where(CatalogState.id == 1).with_for_update())
        yield state


def publish(db, state, kind, entity_id, data):
    state.version += 1
    data = {**data, 'version': state.version}
    db.add(ProductChange(version=state.version, kind=kind, entity_id=entity_id, payload=data))
    return state.version


def upsert(db, state, model, data, kind):
    existing = db.get(model, data['id'])
    values = dict(data)
    if isinstance(existing, Product):
        for key in ('sku', 'barcode'):
            if values.get(key) is not None and getattr(existing,key) not in (None,values[key]):
                raise ValueError(f'Conflicting verified {key} for {existing.id}')
    # Unknown source identifiers cannot erase safely imported identifiers.
    for key in ('sku', 'barcode', 'category_id', 'brand'):
        if values.get(key) is None and existing is not None:
            values.pop(key, None)
    def equal(key, value):
        old = getattr(existing, key)
        return old == (Decimal(str(value)) if isinstance(old, Decimal) and value is not None else value)
    if existing is not None and all(equal(k, v) for k, v in values.items()):
        return 'unchanged'
    if existing is None:
        existing = model(**values)
        db.add(existing)
        status = 'added'
    else:
        for key, value in values.items(): setattr(existing, key, value)
        status = 'updated'
    if isinstance(existing, Product): existing.updated_at = now()
    db.flush()
    existing.version = publish(db, state, kind, existing.id, payload(existing))
    db.flush()
    return status


def put_document(db, state, model, kind, entity_id, data):
    row = db.get(model, entity_id)
    if row is not None and row.data == data: return False
    if row is None:
        row = model(id=entity_id, data=data)
        db.add(row)
    else:
        row.data = data
    row.version = publish(db, state, kind, entity_id, {**data, 'id': entity_id})
    db.flush()
    return True
