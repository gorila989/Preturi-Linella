from datetime import datetime, timezone, timedelta
from types import SimpleNamespace
from app.freshness import describe
from app.scheduled import is_due

NOW = datetime(2026, 10, 30, 20, tzinfo=timezone.utc)
def run(hours=1, status='complete'):
    return SimpleNamespace(started_at=NOW-timedelta(hours=hours), status=status)

def test_phone_download_does_not_prove_source_freshness():
    assert describe(None, None, NOW)['status'] == 'unknown'
    good = run(50)
    result = describe(run(1, 'partial'), good, NOW)
    assert result['status'] == 'error'
    assert result['lastSuccessfulCheckAt'] == good.started_at.isoformat()

def test_age_and_running_deadline():
    assert describe(run(), run(), NOW)['status'] == 'fresh'
    assert describe(run(27), run(27), NOW)['status'] == 'stale'
    assert describe(run(13, 'running'), run(2), NOW)['status'] == 'error'
    assert describe(run(-2), run(-2), NOW)['status'] == 'unknown'

def test_daily_refresh_and_failed_retry():
    assert not is_due(describe(run(3),run(3),NOW),NOW)
    assert is_due(describe(run(25),run(25),NOW),NOW)
    assert is_due(describe(run(2,'partial'),run(3),NOW),NOW)
    assert is_due(describe(None,None,NOW),NOW)
