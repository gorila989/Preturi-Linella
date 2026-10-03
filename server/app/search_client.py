from .linella_session import LinellaSession
from .search_models import SearchError, SearchResponse
from .stock_client import StockClient


def search_metrics():
    return dict(searchApiRequests=0, searchApiProducts=0, searchApiFailures=0,
                securityHashRefreshes=0, htmlFallbackRequests=0, stockRequests=0,
                searchUnknownProducts=0, searchPromotionConflicts=0)


class LinellaSearchClient:
    def __init__(self, transport, metrics=None):
        self.metrics = metrics if metrics is not None else search_metrics()
        self.session = LinellaSession(transport, self.metrics)
        self.stock = StockClient(self.session)

    async def initialize_session(self):
        await self.session.initialize_session()

    async def refresh_security_hash(self):
        await self.session.refresh_security_hash()

    async def search(self, query, offset=0, limit=100):
        if not isinstance(query, str) or len(query) > 200:
            raise SearchError('Invalid search query')
        if type(offset) is not int or offset < 0 or type(limit) is not int or not 1 <= limit <= 100:
            raise SearchError('Invalid search pagination')
        if offset+limit > 20000:
            raise SearchError('Search result window exceeds 20000')
        try:
            raw = await self.session.search_json(query, offset, limit)
            result = SearchResponse.parse(raw, query, offset, limit)
        except SearchError:
            self.metrics['searchApiFailures'] += 1
            raise
        self.metrics['searchApiProducts'] += len(result.products)
        return result

    async def collect(self, query, limit=100, max_pages=10):
        # Bounded selective task, never a wildcard full-catalog discovery.
        if not query.strip() or query.strip() in ('*', '%') or not 1 <= max_pages <= 10:
            raise SearchError('Selective search requires a concrete bounded query')
        offset, total = 0, None
        products, seen, offsets, signatures = [], set(), set(), set()
        failures_before = self.metrics['searchApiFailures']
        try:
            for _ in range(max_pages):
                if offset in offsets:
                    raise SearchError('Repeated offset')
                offsets.add(offset)
                page = await self.search(query, offset, limit)
                if total is None:
                    total = page.meta.total
                if total != page.meta.total:
                    raise SearchError('Inconsistent total across pages')
                if total > 20000 or total > limit*max_pages:
                    raise SearchError('Selective search exceeds bounded result budget')
                ids = tuple(p.product_id for p in page.products)
                if (ids and ids in signatures) or seen.intersection(ids):
                    raise SearchError('Repeated page or duplicate product ID')
                signatures.add(ids)
                seen.update(ids)
                products.extend(page.products)
                if not page.meta.has_more:
                    return products
                offset = page.meta.next_offset
            raise SearchError('Search page budget exhausted')
        except SearchError:
            if self.metrics['searchApiFailures'] == failures_before:
                self.metrics['searchApiFailures'] += 1
            raise

    async def get_stock_availability(self, product_id):
        return await self.stock.get_stock_availability(product_id)
