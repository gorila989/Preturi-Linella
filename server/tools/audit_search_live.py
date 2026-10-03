"""Opt-in, bounded read-only comparison. Never writes the production database."""
import argparse
import asyncio
from dataclasses import asdict
from decimal import Decimal
import json
from pathlib import Path
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app.scraper import Fetcher
from app.search_client import LinellaSearchClient
from app.parser import parse_products, next_page


async def main(output):
    fetcher = Fetcher()
    client = LinellaSearchClient(fetcher)
    result = {}
    try:
        started = time.perf_counter()
        products = await client.collect('red bull', limit=100, max_pages=2)
        result['search'] = dict(durationSeconds=time.perf_counter()-started,
            httpRequests=fetcher.requests, products=len(products), metrics=client.metrics.copy(),
            sessionInitialized=client.session.acquired_at is not None,
            cookieCount=len(client.session.cookies))
        started = time.perf_counter()
        initial_requests = fetcher.requests
        url = 'https://linella.md/bauturi/energizante/'
        rows, pages, visited = {}, 0, set()
        while url and pages < 10:
            if url in visited:
                raise ValueError('Repeated HTML page')
            visited.add(url)
            source = await fetcher.get(url)
            items, stats = parse_products(source)
            if stats['ageRestrictedPage'] or stats['ageRestrictedCards']:
                raise ValueError('Restricted comparison scope')
            rows.update({p['source_product_id']: p for p in items})
            pages += 1
            url = next_page(source, url)
        result['html'] = dict(durationSeconds=time.perf_counter()-started,
            httpRequests=fetcher.requests-initial_requests, products=len(rows), complete=url is None)
        common = [p for p in products if p.product_id in rows]
        result['comparison'] = dict(commonIds=len(common),
            priceMatches=sum(Decimal(str(rows[p.product_id]['price'])) == p.price for p in common),
            oldPriceMatches=sum((Decimal(str(rows[p.product_id]['old_price'])) if rows[p.product_id]['old_price'] is not None else None) == p.list_price for p in common),
            productsUpdated=None, note='Read-only live probe; database updates tested separately on isolated PostgreSQL.')
        result['stock'] = asdict(await client.get_stock_availability('32956'))
        result['totalRequests'] = fetcher.requests
    finally:
        await fetcher.close()
    Path(output).write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding='utf-8')
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True)
    asyncio.run(main(parser.parse_args().output))
