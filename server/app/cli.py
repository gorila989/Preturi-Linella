import argparse
import asyncio
import json
import logging
from dataclasses import asdict
from .scraper import Fetcher, Synchronizer
from .importer import import_file, associate


async def sync(selection=None):
    fetcher = Fetcher()
    try:
        job = Synchronizer(fetcher)
        await job.run(selection)
        if job.stats['errors'] or job.stats['skuErrors']: raise SystemExit(1)
    finally:
        await fetcher.close()


async def stock(product_id):
    from .search_client import LinellaSearchClient
    fetcher = Fetcher()
    try:
        client = LinellaSearchClient(fetcher)
        result = await client.get_stock_availability(product_id)
        print(json.dumps(asdict(result), ensure_ascii=False))
        logging.getLogger('linella').info('Stock metrics %s', client.metrics)
    finally:
        await fetcher.close()


async def sku_batch(limit, after):
    from .sku_enrichment import enrich_skus
    fetcher = Fetcher()
    try:
        result = await enrich_skus(fetcher, limit, after)
        print(json.dumps(result, ensure_ascii=False))
        if result['errors'] or result['conflicts']:
            raise SystemExit(1)
    finally:
        await fetcher.close()


def main():
    logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('sync-linella')
    diagnostics = commands.add_parser('diagnose-skus', help='Read-only SKU counts; no credentials printed')
    diagnostics.add_argument('--after', default='')
    diagnostics.add_argument('--render-url', default='')
    sku = commands.add_parser('enrich-skus', help='Add verified SKUs to existing products only')
    sku.add_argument('--limit', type=int, default=100)
    sku.add_argument('--after', default='', help='Resume after the last reported existing product ID')
    selected = commands.add_parser('sync-selected', help='Update known products; HTML fallback, no catalog enumeration')
    selected.add_argument('--query', required=True)
    selected.add_argument('--category', required=True, help='Existing category URL path, e.g. /bauturi/energizante/')
    selected.add_argument('--source-id', action='append', dest='source_ids')
    stock_command = commands.add_parser('stock', help='One on-demand public warehouse lookup, no DB writes')
    stock_command.add_argument('--product-id', required=True)
    importer = commands.add_parser('import-unaretail')
    importer.add_argument('file')
    match = commands.add_parser('associate-identifier')
    match.add_argument('identifier_id')
    match.add_argument('product_id')
    args = parser.parse_args()
    if args.command == 'sync-linella': asyncio.run(sync())
    elif args.command == 'diagnose-skus':
        from .sku_diagnostics import diagnose_skus, compare_render
        try:
            result = diagnose_skus(args.after)
            if args.render_url: compare_render(result, args.render_url)
        except Exception:
            print(json.dumps(dict(database='unavailable', reason='Database diagnostics failed; check connection and schema privately')))
            raise SystemExit(1) from None
        print('database connected')
        print(json.dumps(result, ensure_ascii=False))
        if result['reason'] in ('empty_catalog', 'invalid_after', 'missing_products_before_cursor') or result.get('render_catalog_matches') is False:
            raise SystemExit(1)
    elif args.command == 'enrich-skus':
        try:
            asyncio.run(sku_batch(args.limit, args.after))
        except Exception:
            print(json.dumps(dict(error='SKU batch failed; check diagnostic output. Connection details suppressed.')))
            raise SystemExit(1) from None
    elif args.command == 'sync-selected':
        asyncio.run(sync(dict(query=args.query, category=args.category, source_ids=args.source_ids)))
    elif args.command == 'stock': asyncio.run(stock(args.product_id))
    elif args.command == 'import-unaretail': print(json.dumps(import_file(args.file), ensure_ascii=False))
    else: associate(args.identifier_id, args.product_id)


if __name__ == '__main__': main()
