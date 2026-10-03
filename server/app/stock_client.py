from collections import OrderedDict
from dataclasses import dataclass
from datetime import datetime, timezone
import json
import re
import time
import httpx
from bs4 import BeautifulSoup
from .parser import BASE
from .search_models import SearchError


@dataclass(frozen=True)
class StockAvailability:
    product_id: str
    context: str | None
    entries: tuple[dict, ...]
    checked_at: str


class StockClient:
    def __init__(self, session, ttl=900, capacity=256):
        self.session = session
        self.ttl = ttl
        self.capacity = capacity
        self.cache = OrderedDict()

    async def get_stock_availability(self, product_id):
        if not re.fullmatch(r'[0-9]+', product_id):
            raise SearchError('Invalid stock product ID')
        await self.session.initialize_session()
        # Session generation is part of the key: no cross-context cache reuse.
        key = (product_id, self.session.acquired_at)
        cached = self.cache.get(key)
        if cached and time.monotonic()-cached[0] < self.ttl:
            self.cache.move_to_end(key)
            return cached[1]
        target = 'warehouses_stock_availability_' + product_id
        url = BASE+'index.php?dispatch=warehouses.stock_availability&product_id='+product_id+'&result_ids='+target+'&is_ajax=1'
        def counted():
            self.session.metrics['stockRequests'] += 1
        try:
            body = await self.session.transport.request('GET', url, on_request=counted)
            raw = json.loads(body)
            fragment = raw['html'][target]
            if not isinstance(fragment, str):
                raise ValueError()
            doc = BeautifulSoup(fragment, 'lxml')
            wrapper = doc.select_one('.ty-warehouses-shipping__wrapper')
            if wrapper is None:
                raise ValueError()
            location = wrapper.select_one('.ty-warehouses__geolocation__location')
            entries = []
            # In the live fragment the items are siblings of the heading wrapper.
            # doc contains ONLY html[target], never the surrounding page.
            for item in doc.select('.ty-warehouses-shipping__item'):
                label = item.select_one('.ty-warehouses-shipping__label')
                value = item.select_one('.ty-warehouses-shipping__value')
                if label is not None and value is not None:
                    entries.append({'label': label.get_text(' ', strip=True), 'value': value.get_text(' ', strip=True)})
            result = StockAvailability(product_id, location.get_text(' ', strip=True) if location else None,
                                       tuple(entries), datetime.now(timezone.utc).isoformat())
        except (httpx.HTTPError, UnicodeError, ValueError, KeyError, TypeError):
            raise SearchError('Stock fragment unavailable') from None
        self.cache[key] = (time.monotonic(), result)
        self.cache.move_to_end(key)
        while len(self.cache) > self.capacity:
            self.cache.popitem(last=False)
        return result
