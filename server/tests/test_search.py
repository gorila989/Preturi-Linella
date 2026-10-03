import asyncio
from copy import deepcopy
from decimal import Decimal
import json
from pathlib import Path
from urllib.parse import parse_qs
import httpx
import pytest
from app.scraper import Fetcher
from app.linella_session import extract_security_hash
from app.search_client import LinellaSearchClient
from app.search_models import SearchError, SearchProduct, SearchResponse, parse_price

FIXTURES = Path(__file__).parent/'fixtures'/'search'
REAL = json.loads((FIXTURES/'coca.json').read_text(encoding='utf-8-sig'))
TOKEN1, TOKEN2 = 'synthetic_token_session_one', 'synthetic_token_session_two'


def response(ids=('29835',), offset=0, total=None, limit=100):
    rows = []
    for sid in ids:
        row = deepcopy(REAL['success']['products'][0])
        row.update(product_id=sid, url='https://linella.md/bauturi/energizante/p'+sid+'/',
                   img='https://linella.md/images/thumbnails/400/400/p'+sid+'.jpg')
        rows.append(row)
    total = len(rows)+offset if total is None else total
    more = offset+len(rows) < total
    return {'success': {'products': rows, 'brands': [], 'categories': [],
        'settings': {'show_prices': True, 'need_auth': False},
        'meta': {'query': 'coca', 'offset': offset, 'limit': limit, 'returned': len(rows),
                 'total': total, 'has_more': more, 'next_offset': offset+len(rows) if more else None}}}


def client(handler):
    transport = Fetcher(httpx.AsyncClient(transport=httpx.MockTransport(handler)))
    transport.next_at = 0
    return LinellaSearchClient(transport), transport


async def finish(c, transport, action):
    try:
        return await action(c)
    finally:
        await transport.close()


@pytest.mark.parametrize('value,expected', [('15.99lei','15.99'),('15,99 lei','15.99'),
    ('101lei','101.00'), ('1\xa0234,5 lei','1234.50'), ('0lei','0.00'), (None,None)])
def test_price(value, expected):
    assert parse_price(value) == (Decimal(expected) if expected is not None else None)


@pytest.mark.parametrize('value', ['-1lei','NaNlei','Infinitylei','15.999lei','1,234.56lei','abc15lei',
                                  '10000000000lei', 15.99, 'lei', '12 34lei'])
def test_bad_price(value):
    with pytest.raises(SearchError): parse_price(value)


def test_real_fixture_and_discount():
    page = SearchResponse.parse(REAL, 'coca', 0, 16)
    assert page.meta.total == 151 and len(page.products) == 16
    assert page.brands and page.categories and page.settings['need_auth'] is False
    discounted = next(p for p in page.products if p.product_id == '30139')
    assert discounted.is_discounted
    assert discounted.price == Decimal('21.99') and discounted.list_price == Decimal('23.99')
    assert discounted.discount_percent == Decimal('8.34')
    assert not page.products[0].is_discounted


def test_hash_sources_and_conflicts():
    assert extract_security_hash('<script>_.security_hash = "'+TOKEN1+'";</script>') == TOKEN1
    assert extract_security_hash('<input name="security_hash" value="'+TOKEN1+'">') == TOKEN1
    for source in ['', '<input name="security_hash" value="short">',
                   '<input name="security_hash" value="'+TOKEN1+'"><script>_.security_hash="'+TOKEN2+'";</script>']:
        with pytest.raises(SearchError): extract_security_hash(source)


@pytest.mark.parametrize('mode', ['success','expired','twice','refresh-fails'])
def test_session_cookie_refresh_once(mode):
    counts = {'get':0, 'post':0}
    def handler(req):
        if req.method == 'GET':
            counts['get'] += 1
            n = counts['get']
            body = '<input name="security_hash" value="'+(TOKEN1 if n == 1 else TOKEN2)+'">'
            if mode == 'refresh-fails' and n == 2: body = 'no session config'
            return httpx.Response(200, text=body, headers={'set-cookie':f'sid=public{n}; Path=/'})
        counts['post'] += 1
        data = parse_qs(req.content.decode())
        n = counts['get']
        assert data['security_hash'] == [TOKEN1 if n == 1 else TOKEN2]
        assert f'sid=public{n}' in req.headers['cookie']
        assert data['limit'] == ['100'] and data['is_ajax'] == ['1']
        if mode != 'success' and (counts['post'] == 1 or mode == 'twice'):
            return httpx.Response(200, json={'error_code':'invalid_security_hash'})
        return httpx.Response(200, json=response())
    c,t = client(handler)
    if mode in ('twice','refresh-fails'):
        with pytest.raises(SearchError): asyncio.run(finish(c,t,lambda c:c.search('coca')))
    else:
        result = asyncio.run(finish(c,t,lambda c:c.search('coca')))
        assert result.products[0].product_id == '29835'
        assert c.session.acquired_at is not None
    assert counts['get'] == (1 if mode == 'success' else 2)
    assert counts['post'] <= 2
    assert c.metrics['securityHashRefreshes'] == (0 if mode == 'success' else 1)


@pytest.mark.parametrize('mode', ['html','http403','missing-name','window','missing-price','timeout'])
def test_invalid_responses(mode):
    def handler(req):
        if req.method == 'GET':return httpx.Response(200,text='<input name="security_hash" value="'+TOKEN1+'">')
        if mode == 'html':return httpx.Response(200,text='<html>login</html>')
        if mode == 'http403':return httpx.Response(403,text='forbidden')
        if mode == 'timeout':raise httpx.ReadTimeout('synthetic timeout',request=req)
        if mode == 'window':return httpx.Response(200,json=json.loads((FIXTURES/'window-error.json').read_text(encoding='utf-8-sig')))
        raw=response()
        del raw['success']['products'][0]['name' if mode == 'missing-name' else 'price']
        return httpx.Response(200,json=raw)
    c,t=client(handler)
    with pytest.raises(SearchError):asyncio.run(finish(c,t,lambda c:c.search('coca')))
    assert c.metrics['searchApiFailures'] == 1
    assert c.metrics['securityHashRefreshes'] == 0


@pytest.mark.parametrize('mode', ['ok','duplicate','total','offset','empty','returned','budget'])
def test_bounded_pagination(mode):
    def handler(req):
        if req.method == 'GET':return httpx.Response(200,text='<input name="security_hash" value="'+TOKEN1+'">')
        offset=int(parse_qs(req.content.decode())['offset'][0])
        if not offset:
            raw=response(['1','2'],total=3,limit=2)
            if mode=='budget':raw['success']['meta']['total']=30000
        else:
            raw=response(['3'],offset=2,total=3,limit=2)
            if mode=='duplicate':raw['success']['products'][0]['product_id']='1'
            if mode=='total':raw['success']['meta'].update(total=4,has_more=True,next_offset=3)
            if mode=='offset':raw['success']['meta']['offset']=0
            if mode=='empty':raw['success']['products']=[];raw['success']['meta']['returned']=0
            if mode=='returned':raw['success']['meta']['returned']=2
        return httpx.Response(200,json=raw)
    c,t=client(handler)
    if mode=='ok':assert len(asyncio.run(finish(c,t,lambda c:c.collect('coca',limit=2))))==3
    else:
        with pytest.raises(SearchError):asyncio.run(finish(c,t,lambda c:c.collect('coca',limit=2)))


def test_empty_and_limits():
    page=SearchResponse.parse(response([]), 'coca',0,100)
    assert page.products==() and not page.meta.has_more
    c,t=client(lambda req:pytest.fail('No HTTP expected'))
    async def action(c):
        for offset,limit in [(0,101),(19999,2),(-1,16),(0,0)]:
            with pytest.raises(SearchError):await c.search('coca',offset,limit)
        for query in ['*','%','']:
            with pytest.raises(SearchError):await c.collect(query)
    asyncio.run(finish(c,t,action))


def test_stock_fragment_cache_no_bulk_calls():
    def handler(req):
        if req.url.path == '/':return httpx.Response(200,text='<input name="security_hash" value="'+TOKEN1+'">')
        return httpx.Response(200,json={'html':{'warehouses_stock_availability_32956':
            '<div class="ty-warehouses-shipping__wrapper"><span class="ty-warehouses__geolocation__location">Chisinau</span></div>'
            '<div class="ty-warehouses-shipping__item"><span class="ty-warehouses-shipping__label">In stoc</span>'
            '<span class="ty-warehouses-shipping__value">in 1 magazin</span></div>'}})
    c,t=client(handler)
    async def action(c):
        first=await c.get_stock_availability('32956');second=await c.get_stock_availability('32956')
        assert first==second and first.context=='Chisinau'
        assert first.entries[0]['value']=='in 1 magazin'
        assert '<' not in str(first)
        assert c.metrics['stockRequests']==1 and c.metrics['searchApiRequests']==0
    asyncio.run(finish(c,t,action))


def test_stream_retry_keeps_original_form():
    calls=0
    class Interrupted(httpx.AsyncByteStream):
        async def __aiter__(self):
            yield b'{'
            raise httpx.ReadError('interrupted synthetic stream')
    def handler(req):
        nonlocal calls
        if req.method=='GET':return httpx.Response(200,text='<input name="security_hash" value="'+TOKEN1+'">')
        calls+=1
        assert parse_qs(req.content.decode())['security_hash']==[TOKEN1]
        assert parse_qs(req.content.decode())['query']==['coca']
        if calls==1:return httpx.Response(200,stream=Interrupted())
        return httpx.Response(200,json=response())
    c,t=client(handler)
    assert asyncio.run(finish(c,t,lambda c:c.search('coca'))).meta.returned==1
    assert c.metrics['searchApiRequests']==2


def test_stock_expiry_and_bad_fragment():
    calls=0
    def handler(req):
        nonlocal calls
        if req.url.path=='/':return httpx.Response(200,text='<input name="security_hash" value="'+TOKEN1+'">')
        calls+=1
        if calls==2:return httpx.Response(200,json={'html':{'wrong_id':'<div></div>'}})
        return httpx.Response(200,json={'html':{'warehouses_stock_availability_1':'<div class="ty-warehouses-shipping__wrapper"></div>'}})
    c,t=client(handler)
    c.stock.ttl=0
    async def action(c):
        assert (await c.get_stock_availability('1')).entries==()
        with pytest.raises(SearchError):await c.get_stock_availability('1')
        assert c.metrics['stockRequests']==2
    asyncio.run(finish(c,t,action))


def test_concurrent_session_initialization():
    bootstrap=0
    def handler(req):
        nonlocal bootstrap
        if req.method=='GET':
            bootstrap+=1
            return httpx.Response(200,text='<input name="security_hash" value="'+TOKEN1+'">',headers={'set-cookie':'sid=one; Path=/'})
        assert 'sid=one' in req.headers['cookie']
        return httpx.Response(200,json=response())
    c,t=client(handler)
    async def action(c):
        await asyncio.gather(c.search('coca'),c.search('coca'))
    asyncio.run(finish(c,t,action))
    assert bootstrap==1
