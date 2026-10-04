import asyncio
import json
import pytest
from sqlalchemy import select
from app.db import session
from app.models import Product
from app.sku_diagnostics import diagnose_skus, compare_render
from app.sku_enrichment import enrich_skus
from test_catalog import clean, product, put


def test_counts_and_bounded_blank_enrichment(capsys):
    values = [None, '', ' \t ', '00123', 'bad sku']
    for i, value in enumerate(values):
        p = product(str(90000 + i), 10)
        p['sku'] = value
        put(p)
    report = diagnose_skus()
    assert {k: report[k] for k in ('total_products', 'products_with_sku',
        'products_without_sku', 'products_with_null_sku', 'products_with_empty_sku',
        'products_with_whitespace_sku', 'products_with_valid_sku')} == dict(
            total_products=5, products_with_sku=2, products_without_sku=3,
            products_with_null_sku=1, products_with_empty_sku=1,
            products_with_whitespace_sku=1, products_with_valid_sku=1)
    with session() as db:
        rows = db.scalars(select(Product)).all()
        urls = {p.product_url: p.source_product_id for p in rows}
        before = {p.id: (p.source_product_id, p.price, p.barcode, p.name) for p in rows}
    class Fetcher:
        calls = 0
        async def get(self, url):
            self.calls += 1
            sid = urls[url]
            return f'<input name="product_data[{sid}][product_id]" value="{sid}"><div id="product_code_{sid}"><span class="ut2--sku-text">SKU{sid}</span></div>'
    fetch = Fetcher()
    result = asyncio.run(enrich_skus(fetch, limit=10))
    assert result == dict(checked=3, added=3, unchanged=0, unavailable=0,
                         conflicts=0, errors=0, after='linella:90002')
    assert fetch.calls == 3
    with session() as db:
        rows = db.scalars(select(Product)).all()
        assert {p.id: (p.source_product_id, p.price, p.barcode, p.name) for p in rows} == before
        assert db.get(Product, 'linella:90003').sku == '00123'
        assert db.get(Product, 'linella:90004').sku == 'bad sku'
    assert diagnose_skus()['reason'] == 'all_products_have_sku'
    assert asyncio.run(enrich_skus(fetch, limit=10))['checked'] == 0
    print('LIMIT_10_TEST ' + json.dumps(result))


def test_empty_and_cursor_diagnostics():
    assert diagnose_skus()['reason'] == 'empty_catalog'
    put(product('100', 10), product('200', 20))
    assert diagnose_skus('linella:200')['excluded_by_after'] == 2
    assert diagnose_skus('linella:200')['reason'] == 'missing_products_before_cursor'
    assert diagnose_skus('wrong')['reason'] == 'invalid_after'
    class NoFetch:
        async def get(self, url): pytest.fail('Invalid cursor must not fetch')
    with pytest.raises(ValueError, match='Unknown after'):
        asyncio.run(enrich_skus(NoFetch(), limit=10, after='wrong'))


def test_render_generation_comparison(monkeypatch):
    import httpx
    class Response:
        def raise_for_status(self): pass
        def json(self): return {'generation': 'known'}
    monkeypatch.setattr(httpx, 'get', lambda *a, **kw: Response())
    assert compare_render({'catalog_generation': 'known'}, 'https://example.test')['render_catalog_matches'] is True
    assert compare_render({'catalog_generation': 'different'}, 'https://example.test')['render_catalog_matches'] is False


def test_diagnostic_failure_does_not_expose_secrets(monkeypatch, capsys):
    import sys
    from app import cli, sku_diagnostics
    def fail(*args): raise RuntimeError('postgresql://user:supersecret@private/db')
    monkeypatch.setattr(sku_diagnostics, 'diagnose_skus', fail)
    monkeypatch.setattr(sys, 'argv', ['cli', 'diagnose-skus'])
    with pytest.raises(SystemExit): cli.main()
    captured = capsys.readouterr()
    assert 'supersecret' not in captured.out + captured.err
    assert 'unavailable' in captured.out
