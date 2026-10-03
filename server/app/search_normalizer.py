"""Partial updates: Search never owns identifiers, warehouses or campaign dates."""
from decimal import Decimal
import re
from urllib.parse import urlsplit


def suitable_thumbnail(url):
    if not url:
        return False
    match = re.search(r'/thumbnails/(\d+)/(\d+)/', urlsplit(url).path)
    return bool(match and 0 < int(match[1]) <= 225 and 0 < int(match[2]) <= 225)


def needs_html_image(product, existing):
    if not product.img:
        return False
    if not suitable_thumbnail(existing.thumbnail_url):
        return True
    return urlsplit(product.img).path.rsplit('/', 1)[-1] != urlsplit(existing.thumbnail_url).path.rsplit('/', 1)[-1]


def normalize_product(product, existing, category_id, metrics):
    # Match the existing record selected by source_product_id, even if its
    # local/canonical ID is not the conventional linella:<source ID> spelling.
    patch = dict(id=existing.id, name=product.name, product_url=product.url)
    if product.brand:
        patch['brand'] = product.brand
    if category_id:
        patch['category_id'] = category_id
    if product.img:
        patch['source_image_url'] = product.img
        patch['full_image_url'] = product.img
    # thumbnail_url is deliberately absent: no 400px persistent phone thumbnail.
    # cart_available belongs to the commercial observation, not in_stock.
    if product.price is not None:
        current = Decimal(str(existing.price)) if existing.price is not None else None
        old = Decimal(str(existing.old_price)) if existing.old_price is not None else None
        has_campaign = existing.promotion_state == 'dated' or existing.promotion_start or existing.promotion_end
        # No list price is unknown, not proof that an existing discount expired.
        uncertain_discount = existing.promotion_state == 'observed' and not product.is_discounted
        if (has_campaign or uncertain_discount) and (current != product.price or (product.list_price is not None and old != product.list_price)):
            metrics['searchPromotionConflicts'] += 1
        else:
            patch['price'] = product.price
            if product.is_discounted:
                patch.update(old_price=product.list_price, promo_price=product.price,
                             discount_percent=product.discount_percent)
                if not has_campaign:
                    patch['promotion_state'] = 'observed'
    return patch
