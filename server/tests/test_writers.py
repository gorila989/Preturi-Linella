import os
import threading
from concurrent.futures import ThreadPoolExecutor
from sqlalchemy import select, text
from app.catalog import writer, upsert
from app.db import session
from app.models import Product, ProductChange


def test_concurrent_writer_commit_order_and_identifier_conflict():
    assert os.environ.get('DATABASE_URL','').endswith('/cauta_test')
    with session() as db,db.begin():
        db.execute(text('TRUNCATE product_changes,products CASCADE'))
        db.execute(text('UPDATE catalog_state SET version=0 WHERE id=1'))
    holding=threading.Event(); release=threading.Event(); second_started=threading.Event()
    def first():
        with session() as db,writer(db) as state:
            upsert(db,state,Product,dict(id='linella:1',source_product_id='1',sku='00001',name='A',product_url='https://linella.md/a/'),'product')
            holding.set()
            assert release.wait(5)
    def second():
        second_started.set()
        with session() as db,writer(db) as state:
            upsert(db,state,Product,dict(id='linella:2',source_product_id='2',name='B',product_url='https://linella.md/b/'),'product')
    with ThreadPoolExecutor(2) as pool:
        a=pool.submit(first); assert holding.wait(5)
        b=pool.submit(second); assert second_started.wait(5)
        with session() as db:
            assert list(db.scalars(select(ProductChange)))==[]  # No half-published transaction.
        release.set(); a.result(10);b.result(10)
    with session() as db:
        events=list(db.scalars(select(ProductChange).order_by(ProductChange.version)))
        assert [(e.version,e.entity_id) for e in events]==[(1,'linella:1'),(2,'linella:2')]
    import pytest
    with pytest.raises(ValueError):
        with session() as db,writer(db) as state:
            upsert(db,state,Product,dict(id='linella:1',sku='different'),'product')
    with session() as db: assert db.get(Product,'linella:1').sku=='00001'
