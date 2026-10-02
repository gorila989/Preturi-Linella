"""Central exact-identifier import. Unknown rows remain pending, never guessed."""
import hashlib
import json
import re
from collections import defaultdict
from pathlib import Path
from openpyxl import load_workbook
from sqlalchemy import or_, select
from .models import Product, PendingProductIdentifier
from .catalog import writer, upsert, publish
from .db import session


def identifier(cell):
    value = cell.value
    if value is None or str(value).strip() == '': raise ValueError('Empty identifier')
    if cell.data_type == 'f': raise ValueError('Formula identifier is not safe')
    if isinstance(value, (int, float)):
        if int(value) != value or value < 0 or value >= 10**15: raise ValueError('Unsafe numeric identifier')
        result = str(int(value))
        if re.fullmatch('0+', cell.number_format): result = result.zfill(len(cell.number_format))
        return result
    value = str(value).strip()
    if re.search(r'[\x00-\x1f]|^\d+(?:\.\d+)?[eE][+-]?\d+$', value): raise ValueError('Invalid identifier text')
    return value


def read_rows(path):
    book = load_workbook(path, read_only=True, data_only=False)
    try:
        for sheet in book:
            rows = iter(sheet.rows)
            header = next(rows, ())
            names = [re.sub(r'\s+', '', str(c.value or '').lower()) for c in header]
            if 'coddebare' not in names or 'codprodus' not in names: continue
            barcode_idx, sku_idx = names.index('coddebare'), names.index('codprodus')
            for number, cells in enumerate(rows, 2):
                if all(c.value is None for c in cells): continue
                result = dict(sheetName=sheet.title, rowNumber=number, sourceFile=Path(path).name)
                try:
                    result.update(barcode=identifier(cells[barcode_idx]), sku=identifier(cells[sku_idx]))
                except (ValueError, IndexError) as exc:
                    result.update(errorMessage=str(exc), raw=[str(c.value or '') for c in cells])
                yield result
    finally:
        book.close()


def import_file(path):
    # First pass stores only identifier relationships to flag every ambiguous pair,
    # including the first row of a conflict, before any product is mutated.
    by_sku, by_barcode = defaultdict(set), defaultdict(set)
    for row in read_rows(path):
        if 'errorMessage' not in row:
            by_sku[row['sku']].add(row['barcode'])
            by_barcode[row['barcode']].add(row['sku'])
    counts = dict(read=0, matched=0, pending=0, conflicts=0, invalid=0, duplicate=0)
    for row in read_rows(path):
        counts['read'] += 1
        status = 'invalid' if 'errorMessage' in row else 'pending'
        sku, barcode = row.get('sku'), row.get('barcode')
        if status != 'invalid' and (len(by_sku[sku]) > 1 or len(by_barcode[barcode]) > 1): status = 'needsReview'
        identity = json.dumps(row if status == 'invalid' else [sku, barcode], sort_keys=True)
        key = hashlib.sha256(identity.encode()).hexdigest()
        with session() as db, writer(db) as state:
            prior = db.get(PendingProductIdentifier, key)
            if prior:
                counts['duplicate'] += 1
                continue
            matches = db.scalars(select(Product).where(or_(Product.sku == sku, Product.barcode == barcode))).all() if sku and barcode else []
            matched = None
            if status == 'pending' and matches:
                if len(matches) == 1 and matches[0].sku in (None, sku) and matches[0].barcode in (None, barcode):
                    matched = matches[0].id
                    status = 'matched'
                    upsert(db, state, Product, dict(id=matched, sku=sku, barcode=barcode), 'product')
                else: status = 'needsReview'
            item = PendingProductIdentifier(id=key, sku=sku, barcode=barcode, status=status, product_id=matched, data=row)
            db.add(item)
            item.version = publish(db, state, 'identifier', key, {**row, 'id': key, 'status': status, 'matchedProductId': matched})
            counts[{'needsReview':'conflicts'}.get(status, status)] += 1
    return counts


def associate(identifier_id, product_id):
    """Operator supplies both IDs after verifying the product; no fuzzy matching."""
    with session() as db, writer(db) as state:
        row = db.get(PendingProductIdentifier, identifier_id)
        product = db.get(Product, product_id)
        if row is None or product is None: raise ValueError('Unknown identifier/product ID')
        if not row.sku or not row.barcode: raise ValueError('Invalid import row')
        other = db.scalars(select(Product).where(Product.id != product_id,
            or_(Product.sku == row.sku, Product.barcode == row.barcode))).first()
        if other or product.sku not in (None,row.sku) or product.barcode not in (None,row.barcode):
            raise ValueError('Identifier conflict: association refused')
        upsert(db,state,Product,dict(id=product_id,sku=row.sku,barcode=row.barcode),'product')
        row.status,row.product_id='matched',product_id
        row.version=publish(db,state,'identifier',row.id,{**row.data,'id':row.id,'status':'matched','matchedProductId':product_id})
