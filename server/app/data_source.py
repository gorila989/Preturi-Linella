import json
import logging
import os
from sqlalchemy import select
from .catalog import writer, upsert
from .db import session
from .models import Product
from .search_client import LinellaSearchClient
from .search_models import SearchError
from .search_normalizer import normalize_product, needs_html_image

log = logging.getLogger('linella')


def configured_selections():
    values = json.loads(os.getenv('LINELLA_SEARCH_SELECTIONS', '[]'))
    if not isinstance(values, list) or len(values) > 3:
        raise ValueError('At most three explicit search selections are allowed')
    for value in values:
        if not isinstance(value, dict) or set(value) != {'query', 'category'}:
            raise ValueError('Each selection needs query and category')
    return values


class LinellaDataSource:
    def __init__(self, synchronizer, enabled=None, client=None):
        self.sync = synchronizer
        self.enabled = os.getenv('LINELLA_SEARCH_API_ENABLED', 'false').lower() == 'true' if enabled is None else enabled
        self.client = client or LinellaSearchClient(synchronizer.fetcher, synchronizer.stats)

    async def quick(self, query, category, source_ids=None):
        if not isinstance(query, str) or not query.strip() or query.strip() in ('*', '%'):
            raise ValueError('A concrete search query is required')
        node = next((c for c in self.sync.categories if c['id'] == category), None)
        if node is None:
            raise ValueError('Unknown category; run HTML discovery first')
        targets = set(source_ids) if source_ids is not None else None
        if targets is not None and (not targets or len(targets) > 1000 or any(not s.isdigit() for s in targets)):
            raise ValueError('Invalid selected source IDs')
        descendants = {c['id'] for c in self.sync.categories if c['source_url'].startswith(node['source_url'])}

        async def html(fallback):
            start = self.sync.fetcher.requests
            try:
                if fallback:
                    log.warning('FALLBACK_HTML_USED category=%s', category)
                # Quick scopes never infer disappearance, even in flag-OFF mode.
                with session() as db:
                    known = set(db.scalars(select(Product.source_product_id).where(Product.category_id.in_(descendants))))
                await self.sync.scope(node['source_url'], category=category, only_ids=known if targets is None else known & targets)
            finally:
                if fallback:
                    self.sync.stats['htmlFallbackRequests'] += self.sync.fetcher.requests-start

        if not self.enabled:
            await html(False)
            return
        failures_before = self.sync.stats['searchApiFailures']
        try:
            products = await self.client.collect(query)
            returned_ids = {p.product_id for p in products}
            if not products or (targets is not None and not targets.issubset(returned_ids)):
                raise SearchError('Selected products were not all covered by search')
            # Validate the complete bounded search before making any DB changes.
            with session() as db:
                known = {p.source_product_id: p for p in db.scalars(select(Product).where(
                    Product.source_product_id.in_(returned_ids), Product.category_id.in_(descendants)))}
                needs_images = any(needs_html_image(p, known[p.product_id]) for p in products
                                   if p.product_id in known and (targets is None or p.product_id in targets))
            if not known:
                raise SearchError('No known products matched the selected category')
        except SearchError as exc:
            if self.sync.stats['searchApiFailures'] == failures_before:
                self.sync.stats['searchApiFailures'] += 1
            log.warning('SEARCH_API_FAILED %s', exc)
            await html(True)
            return
        if needs_images:
            # One category fallback, never a detail request per product. Keep
            # discovered 225px URLs; do not manufacture alternate image URLs.
            await html(True)
        with session() as db, writer(db) as state:
            known = {p.source_product_id: p for p in db.scalars(select(Product).where(
                Product.source_product_id.in_(returned_ids), Product.category_id.in_(descendants)))}
            observations = self.sync.stats.setdefault('searchCommercialIndicators', [])
            for product in products:
                existing = known.get(product.product_id)
                if existing is None:
                    self.sync.stats['searchUnknownProducts'] += 1
                    continue
                if targets is not None and product.product_id not in targets:
                    continue
                patch = normalize_product(product, existing, self.sync.category_for(product.url), self.sync.stats)
                result = upsert(db, state, Product, patch, 'product')
                self.sync.stats['products'+result.title()] += 1
                self.sync.stats['promotionsDetected'] += int(product.is_discounted)
                if len(observations) < 1000:
                    observations.append(dict(sourceProductId=product.product_id, categoryLabel=product.category,
                                             cartAvailable=product.cart_available))
