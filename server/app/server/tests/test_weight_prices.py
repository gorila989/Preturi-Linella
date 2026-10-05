import asyncio
import json
from decimal import Decimal
from pathlib import Path
import pytest
import httpx
from sqlalchemy import select
from app.parser import parse_products
from app.scraper import Synchronizer
from app.scraper import Fetcher as HttpFetcher
from app.models import Product, ProductChange
from app.db import session
from test_catalog import clean, product, put

FIXTURES = Path(__file__).parent / 'fixtures'
PLUM = (FIXTURES/'weighted-prunes.html').read_text(encoding='utf-8')
PROMO = (FIXTURES/'weighted-promotion.html').read_text(encoding='utf-8')


def test_real_weighted_price_uses_explicit_kg_not_rounded_step():
    row = parse_products(PLUM)[0][0]
    assert row['price'] == 24.99 and row['quantity'] == '1 kg'
    assert row['old_price'] is None and row['promo_price'] is None
    assert row['promotion_state'] == 'none'


def test_real_weighted_promotion_keeps_old_price_in_kg():
    row = parse_products(PROMO)[0][0]
    assert row['price'] == row['promo_price'] == 3.99
    assert row['old_price'] == 4.99 and row['discount_percent'] == 20
    assert row['quantity'] == '1 kg' and row['promotion_state'] == 'observed'


@pytest.mark.parametrize('step,grams', [('2.49','100'), ('6.24','250'), ('49.98','2000')])
def test_other_explicit_weight_steps(step, grams):
    whole,cents=step.split('.')
    source=PLUM.replace('data-wp-price-step="12.49"',f'data-wp-price-step="{step}"').replace(
        'data-wp-step-g="500"',f'data-wp-step-g="{grams}"').replace('12<sup>49</sup>',f'{whole}<sup>{cents}</sup>')
    assert parse_products(source)[0][0]['price'] == 24.99


@pytest.mark.parametrize('old,new', [
    ('data-wp-price-kg="24.99"','data-wp-price-kg="NaN"'),
    ('data-wp-price-kg="24.99"','data-wp-price-kg="-24.99"'),
    ('data-wp-price-kg="24.99"','data-wp-price-kg="2.499e1"'),
    ('data-wp-price-kg="24.99"','data-wp-price-kg="99.99"'),
    ('data-wp-step-g="500"','data-wp-step-g="0"'),
    ('data-wp-price-step="12.49"','data-wp-price-step="12.50"'),
])
def test_ambiguous_metadata_rejected(old,new):
    with pytest.raises(ValueError): parse_products(PLUM.replace(old,new))


def test_old_price_requires_confirmed_kg_unit():
    with pytest.raises(ValueError,match='old-price unit'):
        parse_products(PROMO.replace('class="wp-old-price-unit"','class="unknown-unit"'))


def test_sync_updates_existing_identity_and_publishes_price_delta(monkeypatch):
    from app import scraper
    p=product('37149',12.49)
    p.update(id='existing:plum',sku='157712',barcode='1234567890123')
    put(p)
    monkeypatch.setattr(scraper,'next_page',lambda *args:None)
    class Fetcher:
        async def get(self,url): return PLUM
    asyncio.run(Synchronizer(Fetcher()).scope('https://linella.md/fructe-si-legume/fructe/'))
    with session() as db:
        row=db.get(Product,'existing:plum')
        assert row.price == Decimal('24.99') and row.sku == '157712' and row.barcode == '1234567890123'
        assert row.source_product_id == '37149'
        assert len(db.scalars(select(Product)).all()) == 1
        last=db.scalars(select(ProductChange).where(ProductChange.kind=='product').order_by(ProductChange.version.desc())).first()
        assert last.payload['price'] == 24.99 and last.payload['id'] == 'existing:plum'


def test_audited_24_products_match_source_unit_prices():
    rows=parse_products((FIXTURES/'weighted-sample.html').read_text(encoding='utf-8'))[0]
    expected=json.loads((FIXTURES/'weighted-sample.json').read_text(encoding='utf-8'))
    assert len(rows) == len(expected) == 24
    for row in rows:
        item=expected[row['source_product_id']]
        assert Decimal(str(row['price'])) == Decimal(item['price'])
        if item['weighted']: assert row['quantity'] == '1 kg'


@pytest.mark.parametrize('destination,allowed', [
    ('https://linella.md/preturi-mici-zi-de-zi/',True),
    ('https://example.com/preturi-mici-zi-de-zi/',False),
    ('https://linella.md/other/',False),
])
def test_only_verified_collection_redirect_is_followed(destination,allowed):
    calls=[]
    def handler(request):
        calls.append(str(request.url))
        return (httpx.Response(301,headers={'location':destination}) if len(calls)==1
                else httpx.Response(200,text='public collection'))
    async def probe():
        f=HttpFetcher(httpx.AsyncClient(transport=httpx.MockTransport(handler)))
        try:return await f.get('https://linella.md/oferte-avantajoase/')
        finally:await f.close()
    if allowed:
        assert asyncio.run(probe()) == 'public collection'
        assert len(calls)==2
    else:
        with pytest.raises(httpx.HTTPStatusError): asyncio.run(probe())
        assert len(calls)==1
