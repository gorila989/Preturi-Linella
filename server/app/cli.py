import argparse
import asyncio
import json
import logging
from .scraper import Fetcher, Synchronizer
from .importer import import_file, associate


async def sync():
    fetcher = Fetcher()
    try:
        job = Synchronizer(fetcher)
        await job.run()
        if job.stats['errors']: raise SystemExit(1)
    finally:
        await fetcher.close()


def main():
    logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('sync-linella')
    importer = commands.add_parser('import-unaretail')
    importer.add_argument('file')
    match = commands.add_parser('associate-identifier')
    match.add_argument('identifier_id')
    match.add_argument('product_id')
    args = parser.parse_args()
    if args.command == 'sync-linella': asyncio.run(sync())
    elif args.command == 'import-unaretail': print(json.dumps(import_file(args.file), ensure_ascii=False))
    else: associate(args.identifier_id, args.product_id)


if __name__ == '__main__': main()
