"""Exact SKU reconciliation within the existing catalog writer transaction."""
from sqlalchemy import select, or_
from .models import Product, PendingProductIdentifier


def reconcile_product(db, state, product):
    from .catalog import publish, payload
    if not product.sku:
        return
    rows = db.scalars(select(PendingProductIdentifier).where(
        PendingProductIdentifier.sku == product.sku,
        PendingProductIdentifier.status != 'invalid')).all()
    candidates = [r for r in rows if r.status == 'pending' and r.barcode]
    for row in candidates:
        related = db.scalars(select(PendingProductIdentifier).where(
            or_(PendingProductIdentifier.sku == row.sku, PendingProductIdentifier.barcode == row.barcode),
            PendingProductIdentifier.status != 'invalid')).all()
        conflict = any(r.sku != row.sku or r.barcode != row.barcode or r.status == 'needsReview'
                       or r.product_id not in (None, product.id) for r in related)
        other = db.scalar(select(Product.id).where(Product.id != product.id,
            or_(Product.sku == row.sku, Product.barcode == row.barcode)))
        conflict = conflict or other is not None or product.barcode not in (None, row.barcode)
        if conflict:
            row.status = 'needsReview'
        else:
            if product.barcode is None:
                product.barcode = row.barcode
                db.flush()
                product.version = publish(db, state, 'product', product.id, payload(product))
            row.status, row.product_id = 'matched', product.id
        row.version = publish(db, state, 'identifier', row.id,
            {**row.data, 'id': row.id, 'status': row.status, 'matchedProductId': row.product_id})
    db.flush()


def reconcile_pending():
    from .db import session
    from .catalog import writer
    after = ''
    while True:
        with session() as db, writer(db) as state:
            rows = db.scalars(select(PendingProductIdentifier).where(
                PendingProductIdentifier.status == 'pending', PendingProductIdentifier.id > after)
                .order_by(PendingProductIdentifier.id).limit(200)).all()
            if not rows:
                return
            after = rows[-1].id
            for row in rows:
                products = db.scalars(select(Product).where(Product.sku == row.sku)).all() if row.sku else []
                if len(products) == 1:
                    reconcile_product(db, state, products[0])
