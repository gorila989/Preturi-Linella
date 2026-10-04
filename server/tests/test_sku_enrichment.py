import asyncio
from pathlib import Path
import pytest
from sqlalchemy import select, func
from app.sku_enrichment import detail_sku, enrich_skus
from app.models import Product, PendingProductIdentifier, ProductChange
from app.db import session
from app.catalog import writer, upsert
from app.importer import import_file
from test_catalog import clean, product, put, FIXTURES
from openpyxl import Workbook

DETAIL = Path(__file__).parent / 'fixtures' / 'sku-detail-30334.html'

def excel(tmp_path, rows):
    p = tmp_path / 'identifiers.xlsx'
    book = Workbook(); s = book.active
    s.append(['Cod de bare', 'Cod produs'])
    for row in rows: s.append(row)
    book.save(p)
    return p

def test_real_detail_exact_identity():
    source = DETAIL.read_text(encoding='utf-8')
    assert detail_sku(source, '30334') == '3579'
    assert detail_sku(source.replace('3579', '003579'), '30334') == '003579'
    with pytest.raises(ValueError): detail_sku(source, '999')
    with pytest.raises(ValueError): detail_sku(source + source.replace('3579', '999'), '30334')
    assert detail_sku('<div class="ty-age-verification__txt">Restricted</div>', '30334') is None

@pytest.mark.parametrize('excel_first', [True, False])
def test_existing_product_enrichment_and_exact_excel(tmp_path, excel_first):
    p = product('30334', 21.99); p.update(id='existing:burn', old_price=23.99, brand='Burn')
    put(p)
    file = excel(tmp_path, [('0001234567890','3579')])
    if excel_first: assert import_file(file)['pending'] == 1
    class Fetcher:
        calls = 0
        async def get(self, url):
            self.calls += 1
            return DETAIL.read_text(encoding='utf-8')
    fetch = Fetcher()
    result = asyncio.run(enrich_skus(fetch))
    assert result['added'] == 1 and result['errors'] == 0
    if not excel_first: assert import_file(file)['matched'] == 1
    with session() as db:
        p = db.get(Product, 'existing:burn')
        assert p.source_product_id == '30334' and p.sku == '3579' and p.barcode == '0001234567890'
        assert str(p.price) == '21.99' and str(p.old_price) == '23.99' and p.brand == 'Burn'
        assert db.scalar(select(func.count()).select_from(Product)) == 1
        assert db.scalar(select(PendingProductIdentifier)).status == 'matched'
        events = db.scalars(select(ProductChange).where(ProductChange.kind == 'product').order_by(ProductChange.version)).all()
        assert events[-1].payload['barcode'] == '0001234567890'
    assert asyncio.run(enrich_skus(fetch))['checked'] == 0
    assert fetch.calls == 1
    assert import_file(file)['duplicate'] == 1

@pytest.mark.parametrize('kind', ['sku_owner','barcode_owner','ambiguous','cross_file'])
def test_conflicts_preserve_existing(tmp_path, kind):
    p = product('30334', 10); put(p)
    if kind == 'sku_owner':
        other = product('999', 99); other['sku'] = '3579'; put(other)
    elif kind == 'barcode_owner':
        other = product('999', 99); other.update(sku='other', barcode='0001'); put(other)
    file = excel(tmp_path, [('0001', '3579')] + ([('0002','3579')] if kind == 'ambiguous' else []))
    import_file(file)
    if kind == 'cross_file': import_file(excel(tmp_path, [('0002','3579')]))
    class Fetcher:
        async def get(self, url): return DETAIL.read_text(encoding='utf-8')
    asyncio.run(enrich_skus(Fetcher(), limit=1))
    with session() as db:
        p = db.get(Product,'linella:30334')
        assert p.source_product_id == '30334' and p.price == 10 and p.barcode is None
        if kind == 'sku_owner': assert p.sku is None
        if kind == 'barcode_owner': assert db.get(Product,'linella:999').barcode == '0001'


def test_failed_detail_does_not_change_catalog():
    put(product('30334', 10))
    class Fetcher:
        async def get(self, url): raise TimeoutError()
    assert asyncio.run(enrich_skus(Fetcher()))['errors'] == 1
    with session() as db: assert db.get(Product,'linella:30334').sku is None


def test_real_excel_pending_reconciles_when_sku_arrives():
    counts = import_file(FIXTURES/'unaretail.xlsx')
    assert counts['read'] == 1559
    with session() as db:
        row = db.scalar(select(PendingProductIdentifier).where(PendingProductIdentifier.status=='pending'))
        sku, barcode = row.sku, row.barcode
    p = product('999991', 12); p['sku'] = sku; put(p)
    with session() as db:
        assert db.get(Product,p['id']).barcode == barcode
        assert db.scalar(select(func.count()).select_from(Product)) == 1

def test_product_source_identity_is_immutable_and_missing_fields_preserved():
    put(product('30334', 10))
    with pytest.raises(ValueError, match='source_product_id'):
        put(dict(id='linella:30334', source_product_id='999'))
    put(dict(id='linella:30334', source_product_id=None, price=11))
    with session() as db:
        p = db.get(Product,'linella:30334')
        assert p.source_product_id == '30334' and p.price == 11
