"""Source verification is separate from API health and phone downloads."""
from datetime import datetime, timezone, timedelta
from sqlalchemy import select
from .models import SyncRun

MAX_AGE_HOURS = 26

def describe(latest, successful, at=None):
    at = at or datetime.now(timezone.utc)
    checked = successful.started_at if successful else None
    status = 'unknown'
    if checked and checked <= at:
        status = 'fresh' if at - checked <= timedelta(hours=MAX_AGE_HOURS) else 'stale'
    if latest and latest.status in ('partial', 'failed', 'interrupted'):
        status = 'error'
    elif latest and latest.status == 'running':
        status = 'running' if at - latest.started_at <= timedelta(hours=12) else 'error'
    return dict(status=status, maxAgeHours=MAX_AGE_HOURS,
                lastSuccessfulCheckAt=checked.isoformat() if checked else None,
                lastAttemptAt=latest.started_at.isoformat() if latest else None,
                lastAttemptStatus=latest.status if latest else None,
                errorCode=(getattr(latest, 'stats', None) or {}).get('sourceError') if latest else None,
                serverTime=at.isoformat())

def source_freshness(db):
    full = SyncRun.stats['scope'].astext == 'full'
    latest = db.scalar(select(SyncRun).where(full).order_by(SyncRun.started_at.desc()).limit(1))
    success = db.scalar(select(SyncRun).where(full,
        SyncRun.stats['priceRefreshComplete'].astext == 'true')
        .order_by(SyncRun.started_at.desc()).limit(1))
    return describe(latest, success)
