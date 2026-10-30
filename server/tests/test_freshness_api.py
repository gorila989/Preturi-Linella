import os
from datetime import datetime, timezone, timedelta
from fastapi.testclient import TestClient
from sqlalchemy import delete
from app.api import app
from app.db import session
from app.models import SyncRun

def test_api_reports_source_failure_without_marking_download_as_source_check():
    assert os.environ['DATABASE_URL'].endswith('/cauta_test')
    at = datetime.now(timezone.utc)
    with session() as db, db.begin():
        db.execute(delete(SyncRun))
        db.add(SyncRun(started_at=at-timedelta(days=8), finished_at=at-timedelta(days=8), status='complete',
            stats={'scope':'full','priceRefreshComplete':True}))
        db.add(SyncRun(started_at=at-timedelta(minutes=5),finished_at=at,status='partial',
            stats={'scope':'full','priceRefreshComplete':False,'sourceError':'access_denied'}))
    client=TestClient(app)
    for route in ['/api/v1/health','/api/v1/sync?since=0&limit=1','/api/v1/catalog/bootstrap?limit=1']:
        response=client.get(route)
        assert response.status_code==200
        result=response.json()['freshness']
        assert result['status']=='error'
        assert result['errorCode']=='access_denied'
        assert datetime.fromisoformat(result['lastSuccessfulCheckAt']) == at-timedelta(days=8)
    with session() as db, db.begin():
        db.execute(delete(SyncRun))
