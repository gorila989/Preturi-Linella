import asyncio
import json
from decimal import Decimal
from pathlib import Path
import pytest
from sqlalchemy import select, func
from app.db import session
from app.models import Product, PendingProductIdentifier
from app.scraper import Synchronizer
from app.importer import import_file, identifier
from app.sku_enrichment import detail_sku
from test_catalog import clean, product, put, FIXTURES, client
from test_sku_enrichment import excel

REAL = json.loads((FIXTURES/'sku-verified-products.json').read_text(encoding='utf-8'))

def listing():
    return ''.join(f'''<div class="ut2-gl__item"><input name="product_data[{p['sourceProductId']}][product_id]" value="{p['sourceProductId']}"><a class="product-title" href="{p['url']}">{p['name']}</a><span id="sec_discounted_price_{p['sourceProductId']}">{p['price']}</span></div>''' for entry in REAL for p in entry['verified'])

class PublicFixtures:
    requests = 0
    async def get(self, url):
        self.requests += 1
        if url == 'https://linella.md/test-list/': return listing()
        p=next(p for e in REAL for p in e['verified'] if p['url']==url)
        return (Path(__file__).parent/'fixtures'/f"sku-detail-{p['sourceProductId']}.html").read_text(encoding='utf-8')


def test_sync_extracts_real_sku_without_excel_then_exact_join_full_file():
    fetch = PublicFixtures(); job=Synchronizer(fetch); job.enrich_sku=True
    asyncio.run(job.scope('https://linella.md/test-list/'))
    with session() as db:
        assert db.scalar(select(func.count()).select_from(Product)) == 4
        for entry in REAL:
            actual=entry['verified'][0]
            p=db.get(Product,'linella:'+actual['sourceProductId'])
            assert p.sku==entry['sku'] and p.barcode is None
            assert p.source_product_id != p.sku and p.price==Decimal(actual['price'])
    assert job.stats['skusExtracted']==4
    # A new sync skips all already verified SKUs.
    again=Synchronizer(fetch); again.enrich_sku=True
    before=fetch.requests
    asyncio.run(again.scope('https://linella.md/test-list/'))
    assert fetch.requests-before==1
    counts=import_file(FIXTURES/'unaretail.xlsx')
    assert counts['matched']==3 and counts['conflicts']==175
    with session() as db:
        for entry in REAL:
            actual=entry['verified'][0]
            p=db.get(Product,'linella:'+actual['sourceProductId'])
            assert p.barcode==(None if entry['sku']=='2003985' else entry['barcode'])
            assert p.price==Decimal(actual['price'])
    bootstrap=client.get('/api/v1/catalog/bootstrap?limit=250').json()
    # Products retain separate sourceProductId and SKU in public API payloads.
    for change in bootstrap['changes']:
        if change['kind']=='product': assert change['data']['sourceProductId'] != change['data']['sku']
    repeated=import_file(FIXTURES/'unaretail.xlsx')
    assert repeated['alreadyMatched']==3 and repeated['matched']==0

@pytest.mark.parametrize('entry',REAL)
def test_each_requested_pair_in_isolation(tmp_path,entry):
    actual=entry['verified'][0]
    p=product(actual['sourceProductId'],actual['price']);p.update(sku=entry['sku'],name=actual['name'])
    put(p)
    file=excel(tmp_path,[(entry['barcode'],entry['sku'])])
    assert import_file(file)['matched']==1
    with session() as db:
        assert db.get(Product,p['id']).barcode==entry['barcode']
    assert import_file(file)['alreadyMatched']==1


def test_no_match_by_source_id_or_existing_barcode(tmp_path):
    p=product('279905',1);p['barcode']='4860019002077';put(p)
    counts=import_file(excel(tmp_path,[('4860019002077','279905')]))
    assert counts['matched']==0 and counts['conflicts']==1
    with session() as db:
        assert db.get(Product,p['id']).sku is None
        assert db.scalar(select(func.count()).select_from(Product))==1


def test_decimal_text_identifier_preserves_zeros():
    from openpyxl import Workbook
    cell=Workbook().active['A1'];cell.value=' 279905.0 '
    assert identifier(cell)=='279905'
    cell.value='0000123'; assert identifier(cell)=='0000123'

def test_search_update_also_fetches_missing_sku_from_verified_detail(tmp_path):
    from app.models import Category
    from app.catalog import writer
    from app.search_models import SearchProduct
    from app.data_source import LinellaDataSource
    actual=REAL[0]['verified'][0]; sid=actual['sourceProductId']; cat='/bauturi/'
    with session() as db,writer(db) as state:
        from app.catalog import upsert
        upsert(db,state,Category,dict(id=cat,name='Bauturi',level=0,sort_order=0,source_url='https://linella.md'+cat),'category')
    p=product(sid,10);p.update(category_id=cat,product_url=actual['url']);put(p)
    assert import_file(excel(tmp_path,[(REAL[0]['barcode'],REAL[0]['sku'])]))['pending']==1
    job=Synchronizer(PublicFixtures());job.enrich_sku=True
    job.categories=[dict(id=cat,source_url='https://linella.md'+cat)]
    class Search:
        async def collect(self,query):
            return [SearchProduct(sid,actual['name'],actual['url'],Decimal(actual['price']),None,None,None,None,True)]
    asyncio.run(LinellaDataSource(job,enabled=True,client=Search()).quick('279905',cat))
    with session() as db:
        p=db.get(Product,'linella:'+sid)
        assert p.sku=='279905' and p.barcode=='4860019002077'
        assert p.source_product_id=='29770'
    assert job.stats['skusExtracted']==1
