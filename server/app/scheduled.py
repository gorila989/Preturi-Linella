"""Run from a Render cron every six hours; refresh daily and retry failures."""
from datetime import datetime, timezone, timedelta
from .db import session
from .freshness import source_freshness

def is_due(freshness, at=None):
    at = at or datetime.now(timezone.utc)
    checked = freshness.get('lastSuccessfulCheckAt')
    if not checked or freshness.get('status') in ('error', 'stale', 'unknown'):
        return True
    checked = datetime.fromisoformat(checked)
    return checked > at or at - checked >= timedelta(hours=24)

async def run_if_due():
    with session() as db:
        freshness = source_freshness(db)
    if not is_due(freshness):
        print('Source verification is recent; scheduled refresh skipped.')
        return
    from .cli import sync
    await sync()
