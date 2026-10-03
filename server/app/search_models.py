"""Validated public search responses; no database or HTTP dependencies."""
from dataclasses import dataclass
from decimal import Decimal, ROUND_HALF_UP
import re
from .parser import public_url


class SearchError(ValueError):
    """Safe diagnostic: never include raw responses, cookies or CSRF tokens."""


def parse_price(value):
    if value is None or value == '':
        return None
    if not isinstance(value, str):
        raise SearchError('Invalid monetary type')
    value = value.strip().replace('\xa0', ' ').replace('\u202f', ' ')
    match = re.fullmatch(r'(\d+|\d{1,3}(?: \d{3})+)(?:([.,])(\d{1,2}))?\s*lei', value, re.I)
    if not match:
        raise SearchError('Invalid monetary format')
    number = Decimal(match[1].replace(' ', '') + '.' + (match[3] or '00'))
    if number > Decimal('9999999999.99'):
        raise SearchError('Monetary overflow')
    return number.quantize(Decimal('.01'))


def integer(value, field):
    if type(value) is not int or value < 0:
        raise SearchError('Invalid integer: ' + field)
    return value


@dataclass(frozen=True)
class SearchProduct:
    product_id: str
    name: str
    url: str
    price: Decimal | None
    list_price: Decimal | None
    brand: str | None
    category: str | None
    img: str | None
    cart_available: bool | None
    original_product_id: str | None = None

    @property
    def is_discounted(self):
        return self.price is not None and self.list_price is not None and self.list_price > self.price

    @property
    def discount_percent(self):
        if not self.is_discounted:
            return None
        return ((self.list_price-self.price)*100/self.list_price).quantize(Decimal('.01'), rounding=ROUND_HALF_UP)

    @classmethod
    def parse(cls, value):
        if not isinstance(value, dict):
            raise SearchError('Invalid product')
        sid = value.get('product_id')
        if not isinstance(sid, str) or not re.fullmatch(r'[0-9]+', sid):
            raise SearchError('Missing product ID')
        if not isinstance(value.get('name'), str) or not value['name'].strip():
            raise SearchError('Missing product name')
        if not isinstance(value.get('url'), str) or not value['url']:
            raise SearchError('Missing product URL')
        for field in ('brand', 'category', 'img', 'original_product_id'):
            if value.get(field) is not None and not isinstance(value[field], str):
                raise SearchError('Invalid product field: ' + field)
        cart = value.get('cart_available')
        if cart is not None and type(cart) is not bool:
            raise SearchError('Invalid cart availability')
        try:
            url = public_url(value['url'])
            img = public_url(value['img']) if value.get('img') else None
        except ValueError:
            raise SearchError('Invalid source URL') from None
        return cls(sid, value['name'].strip(), url, parse_price(value.get('price')),
                   parse_price(value.get('list_price')), value.get('brand') or None,
                   value.get('category') or None, img, cart, value.get('original_product_id'))


@dataclass(frozen=True)
class SearchMeta:
    query: str
    offset: int
    limit: int
    returned: int
    total: int
    has_more: bool
    next_offset: int | None


@dataclass(frozen=True)
class SearchResponse:
    products: tuple[SearchProduct, ...]
    meta: SearchMeta
    brands: list
    categories: list
    settings: dict

    @classmethod
    def parse(cls, raw, query, offset, limit):
        if not isinstance(raw, dict) or not isinstance(raw.get('success'), dict):
            raise SearchError('Search response has no success envelope')
        notices = raw.get('notifications', {})
        if isinstance(notices, dict) and any(isinstance(n, dict) and n.get('type') == 'E' for n in notices.values()):
            raise SearchError('Search API reported an application error')
        data = raw['success']
        if not isinstance(data.get('products'), list) or not isinstance(data.get('meta'), dict):
            raise SearchError('Missing products or metadata')
        meta = data['meta']
        nums = {k: integer(meta.get(k), k) for k in ('offset', 'limit', 'returned', 'total')}
        if meta.get('query') != query or nums['offset'] != offset or nums['limit'] != limit:
            raise SearchError('Search request/response mismatch')
        count = len(data['products'])
        if nums['returned'] != count or count > limit or (count and offset+count > nums['total']):
            raise SearchError('Inconsistent returned count')
        more = meta.get('has_more')
        following = meta.get('next_offset')
        if type(more) is not bool or more != (offset+count < nums['total']):
            raise SearchError('Inconsistent pagination state')
        if more and (count == 0 or type(following) is not int or following != offset+count):
            raise SearchError('Repeated offset or empty intermediate page')
        if not more and following is not None:
            raise SearchError('Unexpected next offset')
        for field in ('brands', 'categories'):
            if not isinstance(data.get(field), list):
                raise SearchError('Missing ' + field)
        if not isinstance(data.get('settings'), dict):
            raise SearchError('Missing settings')
        if data['settings'].get('need_auth') is True:
            raise SearchError('Authentication required')
        products = tuple(SearchProduct.parse(p) for p in data['products'])
        if len({p.product_id for p in products}) != count:
            raise SearchError('Duplicate product ID on page')
        if data['settings'].get('show_prices') is True and any(p.price is None for p in products):
            raise SearchError('Missing advertised price')
        return cls(products, SearchMeta(query, **nums, has_more=more, next_offset=following),
                   data['brands'], data['categories'], data['settings'])
