import json
import os
import time
from pathlib import Path
from fastapi.testclient import TestClient
from sqlalchemy import text
from app.api import app
from app.db import session


def test_postgresql_50000_bootstrap_bounded_pages():
    assert os.environ.get('DATABASE_URL','').endswith('/cauta_test')
    os.environ.setdefault('SYNC_CURSOR_SECRET','test-only-cursor-secret-with-more-than-32-characters')
    with session() as db, db.begin():
        db.execute(text('TRUNCATE product_changes, products, categories, promotions, special_collections, pending_identifiers CASCADE'))
        db.execute(text("INSERT INTO products(id,source_product_id,name,product_url,price,promotion_state,possibly_inactive,inactive,missing_count,created_at,updated_at,version) SELECT 'linella:'||n,n::text,'Product '||n,'https://linella.md/test/'||n,20,'none',false,false,0,now(),now(),n FROM generate_series(1,50000) n"))
        db.execute(text("INSERT INTO product_changes(version,kind,entity_id,payload) SELECT version,'product',id,jsonb_build_object('id',id,'sourceProductId',source_product_id,'name',name,'price',price,'version',version) FROM products"))
        db.execute(text('UPDATE catalog_state SET version=50000 WHERE id=1'))
    started=time.monotonic(); count=0; pages=0; cursor=None; biggest=0
    client=TestClient(app)
    while True:
        response=client.get('/api/v1/catalog/bootstrap',params={'limit':500,**({'cursor':cursor} if cursor else {})})
        assert response.status_code==200
        result=response.json(); pages+=1; count+=len(result['changes']); biggest=max(biggest,len(response.content))
        assert result['serverVersion']==50000 and len(result['changes'])<=500
        cursor=result['nextCursor']
        if cursor is None: break
    assert count==50000 and pages==100
    delta=client.get('/api/v1/sync?since=50000').json()
    assert delta['changes']==[]
    report=dict(products=count,pages=pages,limit=500,elapsedMs=int((time.monotonic()-started)*1000),
                largestDecodedPageBytes=biggest,unchangedDeltaBytes=len(json.dumps(delta)))
    (Path(__file__).resolve().parents[2]/'validation'/'hybrid-backend-scale.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    with session() as db, db.begin():
        db.execute(text('TRUNCATE product_changes, products CASCADE'))
        db.execute(text('UPDATE catalog_state SET version=0 WHERE id=1'))
