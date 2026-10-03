import asyncio
from decimal import Decimal
import json
import os
from pathlib import Path
import time
import httpx
import pytest
from sqlalchemy import select, text, func
from app.catalog import writer, upsert
from app.db import session
from app.models import Category, Product, SyncRun
from app.scraper import Fetcher, Synchronizer
from app.data_source import LinellaDataSource
from app.search_models import SearchError

CAT='/bauturi/energizante/'
TOKEN='synthetic_public_session_token'


@pytest.fixture(autouse=True)
def clean():
    assert os.environ.get('DATABASE_URL','').endswith('/cauta_test')
    with session() as db,db.begin():
        db.execute(text('TRUNCATE product_changes,products,categories,sync_runs CASCADE'))
        db.execute(text('UPDATE catalog_state SET version=0 WHERE id=1'))
        db.add(Category(id=CAT,name='Energizante',level=0,sort_order=0,source_url='https://linella.md'+CAT,version=0))


def seed(count=1, dated=False, no_thumbnail=False):
    with session() as db,writer(db) as state:
        for i in range(count):
            sid=str(29835+i)
            upsert(db,state,Product,dict(id='existing:'+sid,source_product_id=sid,sku='ABC'+sid,
                barcode='4840000'+sid,category_id=CAT,name='Before',price=Decimal('25.00'),
                product_url='https://linella.md'+CAT+'p'+sid+'/',
                thumbnail_url=None if no_thumbnail else 'https://linella.md/images/thumbnails/225/225/p'+sid+'.jpg',
                promotion_state='dated' if dated else 'none',promotion_start='2026-10-01T00:00:00Z' if dated else None,
                promotion_end='2026-10-10T00:00:00Z' if dated else None), 'product')


def search_data(ids, offset=0,total=None):
    total=len(ids)+offset if total is None else total
    return {'success':{'products':[dict(product_id=sid,name='After',brand='Coca-Cola',category='Energizante',
        price='21.99lei',list_price='23.99lei',url='https://linella.md'+CAT+'p'+sid+'/',
        img='https://linella.md/images/thumbnails/400/400/p'+sid+'.jpg',cart_available=True) for sid in ids],
        'brands':[],'categories':[],'settings':{'show_prices':True,'need_auth':False},
        'meta':dict(query='coca',offset=offset,limit=100,returned=len(ids),total=total,
                    has_more=offset+len(ids)<total,next_offset=offset+len(ids) if offset+len(ids)<total else None)}}


def html(ids, next_url=None):
    source=''
    for sid in ids:
        source+=f'''<div class="ut2-gl__item"><a class="product-title" href="https://linella.md{CAT}p{sid}/">After</a>
        <input name="product_data[{sid}][product_id]" value="{sid}">
        <span id="sec_discounted_price_{sid}">21<sup>99</sup></span>
        <span id="sec_list_price_{sid}">23<sup>99</sup></span>
        <div class="ut2-gl__image"><img class="ty-pict" src="https://linella.md/images/thumbnails/225/225/p{sid}.jpg"></div></div>'''
    if next_url:source+=f'<link rel="next" href="{next_url}">'
    return source


def setup_job(handler):
    f=Fetcher(httpx.AsyncClient(transport=httpx.MockTransport(handler)))
    s=Synchronizer(f)
    s.categories=[dict(id=CAT,parent_id=None,source_url='https://linella.md'+CAT)]
    return s


@pytest.mark.parametrize('dated',[False,True])
def test_merge_no_duplicate_identifiers_dates_or_400px_thumbnail(dated):
    seed(dated=dated)
    def handler(req):
        if req.method=='GET':return httpx.Response(200,text=f'<input name="security_hash" value="{TOKEN}">')
        return httpx.Response(200,json=search_data(['29835']))
    s=setup_job(handler)
    async def run():
        try:
            source=LinellaDataSource(s,enabled=True)
            await source.quick('coca',CAT)
            await source.quick('coca',CAT)
        finally:await s.fetcher.close()
    asyncio.run(run())
    with session() as db:
        assert db.scalar(select(func.count()).select_from(Product))==1
        p=db.get(Product,'existing:29835')
        assert p.sku=='ABC29835' and p.barcode=='484000029835' and p.brand=='Coca-Cola'
        assert p.thumbnail_url=='https://linella.md/images/thumbnails/225/225/p29835.jpg'
        assert '/400/400/' in p.source_image_url
        assert p.in_stock is None  # cart availability is not warehouse stock
        assert not p.inactive and p.missing_count==0
        if dated:
            assert p.price==Decimal('25.00') and p.promotion_end=='2026-10-10T00:00:00Z'
            assert s.stats['searchPromotionConflicts']==2
        else:
            assert p.price==Decimal('21.99') and p.old_price==Decimal('23.99')
            assert p.discount_percent==Decimal('8.34') and p.promotion_state=='observed'
            assert s.stats['productsUpdated']==1 and s.stats['productsUnchanged']==1
    assert s.stats['stockRequests']==0 and s.stats['htmlFallbackRequests']==0
    assert s.stats['searchCommercialIndicators'][0]['cartAvailable'] is True


@pytest.mark.parametrize('failure',['unavailable','hash','malformed','empty','missing-target'])
def test_fallback_and_preserve_data(failure,caplog):
    seed()
    gets=0
    def handler(req):
        nonlocal gets
        if req.method=='POST':
            if failure=='unavailable':return httpx.Response(403)
            if failure=='hash':return httpx.Response(200,json={'error_code':'expired_security_hash'})
            if failure=='malformed':return httpx.Response(200,text='not-json')
            return httpx.Response(200,json=search_data([] if failure=='empty' else ['999']))
        gets+=1
        if req.url.path=='/':return httpx.Response(200,text=f'<input name="security_hash" value="{TOKEN}">')
        return httpx.Response(200,text=html(['29835']))
    s=setup_job(handler)
    async def run():
        try:await LinellaDataSource(s,enabled=True).quick('coca',CAT,source_ids=['29835'])
        finally:await s.fetcher.close()
    asyncio.run(run())
    assert 'SEARCH_API_FAILED' in caplog.text and 'FALLBACK_HTML_USED' in caplog.text
    assert s.stats['htmlFallbackRequests']==1 and s.stats['searchApiFailures']==1
    assert s.stats['securityHashRefreshes']==int(failure=='hash')
    with session() as db:
        p=db.get(Product,'existing:29835')
        # HTML still uses the existing canonical upsert convention. Selective
        # HTML must resolve existing source IDs too, not add linella:<id> copies.
        assert p.price==Decimal('21.99')
        assert p.sku=='ABC29835'
        assert db.scalar(select(func.count()).select_from(Product))==1


def test_missing_thumbnail_uses_html_once_not_400px_download():
    seed(no_thumbnail=True)
    def handler(req):
        assert '/images/' not in str(req.url)
        if req.method=='POST':return httpx.Response(200,json=search_data(['29835']))
        if req.url.path=='/':return httpx.Response(200,text=f'<input name="security_hash" value="{TOKEN}">')
        return httpx.Response(200,text=html(['29835']))
    s=setup_job(handler)
    async def run():
        try:await LinellaDataSource(s,enabled=True).quick('coca',CAT)
        finally:await s.fetcher.close()
    asyncio.run(run())
    with session() as db:assert '/225/225/' in db.get(Product,'existing:29835').thumbnail_url
    assert s.stats['htmlFallbackRequests']==1


def test_partial_search_not_applied_before_fallback_failure():
    seed()
    def handler(req):
        if req.url.path=='/':return httpx.Response(200,text=f'<input name="security_hash" value="{TOKEN}">')
        if req.method=='POST':return httpx.Response(200,json=search_data(['29835'],total=30000))
        return httpx.Response(403)
    s=setup_job(handler)
    async def run():
        try:await LinellaDataSource(s,enabled=True).quick('coca',CAT)
        finally:await s.fetcher.close()
    with pytest.raises(httpx.HTTPError):asyncio.run(run())
    with session() as db:assert db.get(Product,'existing:29835').price==Decimal('25.00')


def test_same_selective_task_off_on_benchmark(monkeypatch):
    # Same 240 existing products and initial DB values; ten HTML pages vs
    # three Search pages + one session bootstrap. No source detail/image GETs.
    from urllib.parse import parse_qs
    ids=[str(29835+i) for i in range(240)]
    results=[]
    for enabled in (False,True):
        with session() as db,db.begin():db.execute(text('TRUNCATE product_changes,products CASCADE'))
        seed(240)
        def handler(req):
            if req.method=='POST':
                offset=int(parse_qs(req.content.decode())['offset'][0])
                return httpx.Response(200,json=search_data(ids[offset:offset+100],offset,240))
            if req.url.path=='/':return httpx.Response(200,text=f'<input name="security_hash" value="{TOKEN}">')
            n=int(req.url.path.split('page-')[1].strip('/')) if 'page-' in req.url.path else 1
            next_url='https://linella.md'+CAT+f'page-{n+1}/' if n<10 else None
            return httpx.Response(200,text=html(ids[(n-1)*24:n*24],next_url))
        s=setup_job(handler)
        monkeypatch.setenv('LINELLA_SEARCH_API_ENABLED',str(enabled).lower())
        async def run():
            try:await s.run(dict(query='coca',category=CAT,source_ids=ids))
            finally:await s.fetcher.close()
        start=time.perf_counter();asyncio.run(run());duration=time.perf_counter()-start
        with session() as db:
            rows=list(db.scalars(select(Product)))
            assert len(rows)==240 and all(p.price==Decimal('21.99') for p in rows)
            history=db.scalar(select(SyncRun).order_by(SyncRun.started_at.desc()))
            assert history.stats['searchApiRequests']==(3 if enabled else 0)
        results.append(dict(enabled=enabled,durationSeconds=duration,httpRequests=s.fetcher.requests,
                            productsDiscovered=0,knownProducts=240,productsUpdated=s.stats['productsUpdated'],
                            promotionsDetected=s.stats['promotionsDetected'],failures=s.stats['errors'],
                            searchApiFailures=s.stats['searchApiFailures'],fallbackRequests=s.stats['htmlFallbackRequests']))
    assert results[0]['httpRequests']==10 and results[1]['httpRequests']==4
    target=Path(__file__).resolve().parents[2]/'validation'/'phase2-off-on-mock.json'
    target.write_text(json.dumps(results,indent=2),encoding='utf-8')
