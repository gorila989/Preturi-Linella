import asyncio
import json
import os
from pathlib import Path
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select, text, func
from app.api import app
from app.db import session
from app.models import Category, Product, CatalogState, ProductChange
from app.catalog import writer, upsert
from app.parser import parse_products, parse_categories, next_page, parse_promotion, SourceThumbnailStorage
from app.scraper import Synchronizer
from app.importer import import_file, read_rows, identifier, associate

FIXTURES = Path(__file__).resolve().parents[2] / 'test' / 'fixtures'
os.environ.setdefault('SYNC_CURSOR_SECRET', 'test-only-cursor-secret-with-more-than-32-characters')
client = TestClient(app)


@pytest.fixture(autouse=True)
def clean():
    # Explicit test database guard: never truncate a configured production DB.
    assert os.environ.get('DATABASE_URL', '').endswith('/cauta_test')
    with session() as db, db.begin():
        tables = ['product_changes','product_promotions','special_collection_products','pending_identifiers',
                  'products','categories','promotions','special_collections','sync_runs']
        db.execute(text('TRUNCATE '+','.join(tables)+' CASCADE'))
        db.execute(text('UPDATE catalog_state SET version=0'))


def put(*products):
    with session() as db, writer(db) as state:
        return [upsert(db,state,Product,p,'product') for p in products]


def product(id, price):
    return dict(id='linella:'+id, source_product_id=id, name='Product '+id,
                product_url='https://linella.md/test/'+id+'/', price=price, promotion_state='none')


def test_real_html_prices_discounts_thumbnails():
    html = (FIXTURES/'energizante.html').read_text(encoding='utf-8')
    rows, stats = parse_products(html)
    assert len(rows) == 24
    assert stats['promotionalProductsDetected'] == 2
    first = next(p for p in rows if p['source_product_id']=='30374')
    assert first['price'] == 28.19
    assert first['sku'] is None
    assert '/225/225/' in first['thumbnail_url']
    assert '/450/450/' in first['full_image_url']
    assert next_page(html,'https://linella.md/bauturi/energizante/').endswith('/page-2/')
    assert any(p['old_price']==12.99 and p['discount_percent']==46 for p in rows)


def test_real_categories_parent_links():
    rows = parse_categories((FIXTURES/'categories.html').read_text(encoding='utf-8'))
    assert len(rows) > 100
    ids = {p['id'] for p in rows}
    assert all(p['parent_id'] is None or p['parent_id'] in ids for p in rows)
    with session() as db, writer(db) as state:
        for row in rows: upsert(db,state,Category,row,'category')


def test_nested_dom_categories():
    rows = parse_categories('<div class="ab-lc-group"><div class="head"><a href="/a/">A</a></div>'
          '<ul><li><a href="/a/b/">B</a><ul><li><a href="/a/b/c/">C</a></li></ul></li></ul></div>')
    assert rows[-1]['parent_id']=='/a/b/' and rows[-1]['level']==2


def test_real_promotion_period():
    promo = parse_promotion((FIXTURES/'mega.html').read_text(encoding='utf-8'))
    assert promo['endDateTime'] > promo['startDateTime']


def test_delta_only_changes_no_duplicate_upsert():
    assert put(product('1',20), product('2',30)) == ['added','added']
    base = client.get('/api/v1/catalog/bootstrap').json()
    assert len(base['changes'])==2
    assert put(product('1',18), product('2',30), product('3',5))==['updated','unchanged','added']
    delta = client.get('/api/v1/sync',params={'since':base['serverVersion']}).json()
    assert [p['id'] for p in delta['changes']]==['linella:1','linella:3']
    assert client.get('/api/v1/products/linella:1').json()['price']==18
    assert len(client.get('/api/v1/products').json()['items'])==3


def test_snapshot_pagination_excludes_concurrent_writes_and_rejects_tampering():
    put(product('1',20),product('2',30))
    page = client.get('/api/v1/catalog/bootstrap?limit=1').json()
    put(product('2',40),product('3',50))
    next = client.get('/api/v1/catalog/bootstrap',params={'cursor':page['nextCursor'],'limit':1}).json()
    assert next['serverVersion']==page['serverVersion']
    assert next['changes'][0]['data']['price']==30
    assert next['nextCursor'] is None
    assert client.get('/api/v1/catalog/bootstrap',params={'cursor':page['nextCursor']+'x'}).status_code==400
    assert client.get('/api/v1/sync?generation=wrong').status_code==409


def test_rollback_does_not_publish_version():
    with pytest.raises(RuntimeError):
        with session() as db, writer(db) as state:
            upsert(db,state,Product,product('1',20),'product')
            raise RuntimeError('interrupt')
    assert client.get('/api/v1/catalog/bootstrap').json()['serverVersion']==0
    assert put(product('1',20))==['added']
    assert client.get('/api/v1/catalog/bootstrap').json()['serverVersion']==1


def test_real_upsert_unchanged_decimal():
    rows,_ = parse_products((FIXTURES/'energizante.html').read_text(encoding='utf-8'))
    put(*rows)
    assert put(*rows)==['unchanged']*24


def card(id, price=10, old=None):
    return f'<div class="ut2-gl__item"><input name="product_data[{id}][product_id]" value="{id}">'
    # supplied below using explicit markup in pagination test


def test_all_pages_discount_and_no_detail_requests():
    def page(id, next=None):
        return (f'<div class="ut2-gl__item"><input name="product_data[{id}][product_id]" value="{id}">'
            f'<a class="product-title" href="/a/{id}/">Test</a><span id="sec_discounted_price_{id}">10<sup>00</sup></span>'
            f'<span id="sec_list_price_{id}">20<sup>00</sup></span></div>' +
            (f'<a rel="next" href="{next}">next</a>' if next else ''))
    class Fake:
        requests=0
        async def get(self,url):
            self.requests+=1
            return page('1','/a/page-2/') if self.requests==1 else page('2')
    fake=Fake(); job=Synchronizer(fake)
    assert len(asyncio.run(job.scope('https://linella.md/a/')))==2
    assert fake.requests==2 and job.stats['productDetailPagesDownloaded']==0
    assert job.stats['promotionsDetected']==2
    assert all(p['data']['discountPercent']==50 for p in client.get('/api/v1/catalog/bootstrap').json()['changes'])


def test_real_import_no_guessing_repeat_and_zeros():
    path=FIXTURES/'unaretail.xlsx'
    rows=list(read_rows(path))
    assert len(rows)==1559 and rows[0]['barcode']=='4860019002077' and rows[0]['sku']=='279905'
    first=import_file(path)
    assert first['pending']==1384 and first['conflicts']==175 and first['matched']==0
    assert import_file(path)['duplicate']==1559
    assert len(client.get('/api/v1/products').json()['items'])==0


def test_bootstrap_real_fixture_export_for_flutter():
    categories=parse_categories((FIXTURES/'categories.html').read_text(encoding='utf-8'))
    branch=[c for c in categories if c['id'] in ('/bauturi/','/bauturi/energizante/')]
    assert len(branch)==2 and branch[1]['parent_id']=='/bauturi/'
    with session() as db, writer(db) as state:
        for c in branch: upsert(db,state,Category,c,'category')
    rows,_=parse_products((FIXTURES/'energizante.html').read_text(encoding='utf-8'),'/bauturi/energizante/')
    put(*rows)
    response=client.get('/api/v1/catalog/bootstrap')
    assert response.status_code==200
    data=response.json()
    assert sum(p['data'].get('promotionState')=='observed' for p in data['changes'])==2
    # Generated from real PostgreSQL through FastAPI, consumed by Flutter test.
    (FIXTURES/'api_bootstrap.json').write_text(json.dumps(data,ensure_ascii=False),encoding='utf-8')


def test_api_public_read_only_and_health():
    assert client.get('/api/v1/health').json()['database']=='postgresql'
    assert client.post('/api/v1/sync').status_code==405
    assert client.get('/api/v1/products?limit=50000').status_code==422


def test_numeric_identifier_zero_format_and_formulas():
    from openpyxl import Workbook
    c=Workbook().active['A1'];c.value='0012345678901'
    assert identifier(c)=='0012345678901'
    c.value=123; c.number_format='00000'; assert identifier(c)=='00123'
    c.value='=123'
    with pytest.raises(ValueError): identifier(c)
    c.value=1234567890123456
    with pytest.raises(ValueError): identifier(c)


def test_pagination_loop_preserves_scope_and_absence_needs_three_complete_runs():
    cat=dict(id='/a/',parent_id=None,name='A',level=0,sort_order=0,source_url='https://linella.md/a/')
    with session() as db, writer(db) as state: upsert(db,state,Category,cat,'category')
    put({**product('9',20),'category_id':'/a/'})
    html=('<div class="ut2-gl__item"><input name="product_data[1][product_id]" value="1">'
          '<a class="product-title" href="/a/1/">Present</a><span id="sec_discounted_price_1">10</span></div>')
    class Fake:
        requests=0
        loop=True
        async def get(self,url):
            self.requests+=1
            return html+('<a rel="next" href="/a/">next</a>' if self.loop else '')
    fake=Fake(); job=Synchronizer(fake); job.categories=[cat]
    with pytest.raises(ValueError): asyncio.run(job.scope(cat['source_url'],category=cat['id']))
    assert client.get('/api/v1/products/linella:9').json()['missingCount']==0
    fake.loop=False
    for n in range(3):
        asyncio.run(job.scope(cat['source_url'],category=cat['id']))
        row=client.get('/api/v1/products/linella:9').json()
        assert row['missingCount']==n+1 and row['possiblyInactive']
        assert row['inactive']==(n==2)


def test_central_exact_association_and_delta(tmp_path):
    from openpyxl import Workbook
    book=Workbook(); sheet=book.active
    sheet.append(['Cod de bare','Cod produs']); sheet.append(['001234','00001'])
    path=tmp_path/'identifiers.xlsx'; book.save(path)
    assert import_file(path)['pending']==1
    put(product('1',18))
    base=client.get('/api/v1/catalog/bootstrap').json()
    item=next(c for c in base['changes'] if c['kind']=='identifier')
    associate(item['id'],'linella:1')
    changes=client.get('/api/v1/sync',params={'since':base['serverVersion']}).json()['changes']
    assert [c['kind'] for c in changes]==['product','identifier']
    assert changes[0]['data']['barcode']=='001234' and changes[0]['data']['sku']=='00001'
