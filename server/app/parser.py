"""DOM selectors verified against test/fixtures/energizante.html (user HTML)."""
import re
from decimal import Decimal, InvalidOperation
from datetime import datetime, time, timezone
from zoneinfo import ZoneInfo
from urllib.parse import urljoin, urlsplit, urlunsplit
from bs4 import BeautifulSoup

BASE = 'https://linella.md/'


def public_url(raw, base=BASE):
    p = urlsplit(urljoin(base, raw))
    if p.scheme != 'https' or p.hostname != 'linella.md' or p.port not in (None, 443) or p.username:
        raise ValueError('Unexpected source URL')
    return urlunsplit((p.scheme, p.netloc, p.path, p.query, ''))


def money(element):
    if element is None:
        return None
    copy = BeautifulSoup(str(element), 'lxml')
    sup = copy.select_one('sup')
    cents = sup.get_text(strip=True) if sup else None
    if sup:
        sup.decompose()
    value = re.sub(r'[^0-9,.]', '', copy.get_text()).replace(',', '.')
    if cents is not None:
        value += '.' + cents
    try:
        return float(Decimal(value).quantize(Decimal('.01')))
    except InvalidOperation:
        raise ValueError('Invalid price markup')


def weight_prices(card, price, old):
    """Normalize explicitly marked loose goods to lei/kg; never infer from name."""
    nodes = card.select('.wp-product-pricing, [data-wp-price-kg]')
    if not nodes:
        if card.select_one('.wp-step-label, .wp-price-per-kg'):
            raise ValueError('Weighted price metadata missing; previous data preserved')
        return price, old, False
    if len(nodes) != 1:
        raise ValueError('Ambiguous weighted price metadata')
    node = nodes[0]
    def number(key):
        raw = node.get(key, '')
        if not re.fullmatch(r'\d{1,10}(?:\.\d{1,2})?', raw):
            raise ValueError('Invalid weighted price metadata: ' + key)
        value = Decimal(raw)
        if value > Decimal('9999999999.99'):
            raise ValueError('Weighted price overflow')
        return value
    kg, step, grams = (number(k) for k in ('data-wp-price-kg', 'data-wp-price-step', 'data-wp-step-g'))
    if grams <= 0 or price is None or Decimal(str(price)) != step:
        raise ValueError('Inconsistent weighted display price')
    # Source step prices may be truncated by a cent. The explicit kg value
    # remains authoritative; multiplying the rounded display loses precision.
    if abs(kg * grams / 1000 - step) > Decimal('0.01'):
        raise ValueError('Inconsistent weighted price units')
    if old is not None:
        unit = card.select_one('.wp-old-price-unit')
        if unit is None or unit.get_text(' ', strip=True).lower() != 'per kg':
            raise ValueError('Unknown weighted old-price unit; previous data preserved')
        if Decimal(str(old)) < kg:
            raise ValueError('Weighted old price is below current price')
    return float(kg), old, True


class SourceThumbnailStorage:
    """Public source URLs, no persistent files on Render's ephemeral disk.

    Replace this adapter with object storage when generating custom WebP.
    Only accept an explicitly present source thumbnail of <=225px.
    """
    def urls(self, img):
        if img is None:
            return None, None
        candidates = []
        for key in ('data-src', 'src', 'data-srcset', 'srcset'):
            for item in img.get(key, '').split(','):
                parts = item.strip().split()
                if parts and not parts[0].startswith('data:'):
                    url = public_url(parts[0])
                    if url not in candidates:
                        candidates.append(url)
        thumbs = [u for u in candidates if (m := re.search(r'/thumbnails/(\d+)/(\d+)/', u))
                  and 0 < int(m[1]) <= 225 and 0 < int(m[2]) <= 225]
        return (thumbs[0] if thumbs else None, candidates[-1] if candidates else None)


def parse_products(source, category_id=None):
    doc = BeautifulSoup(source, 'lxml')
    products = []
    cards = doc.select('.ut2-gl__item')
    restricted = 0
    page_restricted = not cards and doc.select_one('.ty-age-verification__txt') is not None
    for card in cards:
        # The live source replaces restricted products with an age-check card.
        # Do not infer identifiers/prices or submit an age confirmation.
        if card.select_one('.ty-age-verification__block') is not None:
            restricted += 1
            continue
        title = card.select_one('a.product-title')
        identity = card.select_one('input[name$="[product_id]"]')
        if title is None or identity is None:
            raise ValueError('Unrecognized product card; refusing partial page')
        sid = identity.get('value', '')
        if not sid.isdigit():
            raise ValueError('Missing source product ID')
        price = money(card.select_one('[id^="sec_discounted_price_"]'))
        old = money(card.select_one('[id^="sec_list_price_"]'))
        price, old, weighted = weight_prices(card, price, old)
        discount = card.select_one('[id^="line_discount_value_"]')
        match = re.search(r'(\d+(?:[.,]\d+)?)', discount.get_text()) if discount else None
        percent = float(match[1].replace(',', '.')) if match else None
        observed = price is not None and ((old is not None and old > price) or (percent or 0) > 0)
        if percent is None and observed and old:
            percent = round((old - price) / old * 100, 2)
        thumb, full = SourceThumbnailStorage().urls(card.select_one('.ut2-gl__image img.ty-pict, .product_icon_lnk img'))
        sku_node = card.select_one('[id^="product_code_"] .ty-control-group__item')
        name = title.get_text(' ', strip=True)
        quantity = re.search(r'\b\d+(?:[.,]\d+)?\s*(?:kg|g|ml|l|buc)\b', name, re.I)
        products.append(dict(id=f'linella:{sid}', source_product_id=sid,
            name=name, sku=sku_node.get_text(strip=True) if sku_node else None,
            quantity='1 kg' if weighted else quantity[0] if quantity else None, price=price, old_price=old,
            promo_price=price if observed else None, discount_percent=percent,
            promotion_state='observed' if observed else 'none', promotion_start=None, promotion_end=None,
            category_id=category_id, product_url=public_url(title['href']),
            thumbnail_url=thumb, source_image_url=full, full_image_url=full,
            in_stock=True if card.select_one('.ty-qty-in-stock') else
                     False if card.select_one('.ty-qty-out-of-stock') else None,
            possibly_inactive=False, inactive=False, missing_count=0))
    if not products and not restricted and not page_restricted and doc.select_one('.ty-no-items') is None:
        raise ValueError('Product list not recognized; previous data preserved')
    stats = dict(productsFound=len(products), productsWithCurrentPrice=sum(p['price'] is not None for p in products),
                 productsWithOldPrice=sum(p['old_price'] is not None for p in products),
                 productsWithDiscount=sum((p['discount_percent'] or 0) > 0 for p in products),
                 promotionalProductsDetected=sum(p['promotion_state'] == 'observed' for p in products),
                 ageRestrictedCards=restricted, ageRestrictedPage=page_restricted)
    return products, stats


def next_page(source, current):
    doc = BeautifulSoup(source, 'lxml')
    link = doc.select_one('link[rel="next"], a[rel="next"], a.ty-pagination__next:not(.disabled)')
    href = link.get('href') if link else None
    if not href:
        link = doc.select_one('[data-ut2-load-more-url]')
        href = link.get('data-ut2-load-more-url') if link else None
    if not href or href == '#':
        return None
    return public_url(href, current)


def parse_categories(source):
    doc = BeautifulSoup(source, 'lxml')
    nodes = {}
    def add(a, parent, level):
        url = public_url(a['href'])
        cid = urlsplit(url).path
        if cid not in nodes:
            nodes[cid] = dict(id=cid, parent_id=parent, name=a.get_text(' ', strip=True), level=level,
                              sort_order=len(nodes), source_url=url)
        elif nodes[cid]['parent_id'] != parent:
            raise ValueError(f'Category appears under conflicting parents: {cid}')
        return cid
    for group in doc.select('.ab-lc-group'):
        head = group.select_one('.head a[href]')
        if not head:
            continue
        root = add(head, None, 0)
        for a in group.select('ul a[href]'):
            ancestors = []
            for li in a.parents:
                if li is group:
                    break
                if li.name == 'li':
                    own = li.find('a', recursive=False)
                    if own is not None and own is not a:
                        ancestors.append(own)
            parent, level = root, 1
            for ancestor in reversed(ancestors):
                parent = add(ancestor, parent, level)
                level += 1
            add(a, parent, level)
    if not nodes:
        raise ValueError('Category tree not recognized')
    return list(nodes.values())


def parse_promotion(source):
    doc = BeautifulSoup(source, 'lxml')
    node = doc.select_one('.ab__dotd_promotion_date')
    dates = re.findall(r'(\d{2})[/.](\d{2})[/.](\d{4})', node.get_text() if node else '')
    if len(dates) < 2:
        raise ValueError('Mega period missing')
    days = [datetime(int(y), int(m), int(d)).date() for d, m, y in dates[:2]]
    if days[1] < days[0]:
        raise ValueError('Reversed Mega period')
    zone = ZoneInfo('Europe/Chisinau')
    stamp = lambda day, t: datetime.combine(day, t, zone).astimezone(timezone.utc).isoformat()
    return dict(id=f'mega:{days[0]}', name='Mega Ofertă', type='mega',
                startDateTime=stamp(days[0], time.min), endDateTime=stamp(days[1], time(23,59,59,999000)),
                sourceUrl=BASE+'mega-oferta/')
