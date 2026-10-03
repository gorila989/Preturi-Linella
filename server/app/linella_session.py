"""Public session bootstrap only. Does not confirm age or authenticate users."""
import asyncio
from datetime import datetime, timezone
import json
import re
import httpx
from bs4 import BeautifulSoup
from .parser import BASE
from .search_models import SearchError


def extract_security_hash(source):
    doc = BeautifulSoup(source, 'lxml')
    values = {n.get('value', '') for n in doc.select('input[name="security_hash"]')}
    for script in doc.find_all('script'):
        values.update(re.findall(r"\b(?:_|Tygh)\.security_hash\s*=\s*['\"]([A-Za-z0-9_-]+)['\"]", script.get_text()))
    values.discard('')
    if len(values) != 1 or not re.fullmatch(r'[A-Za-z0-9_-]{16,256}', next(iter(values), '')):
        raise SearchError('Missing or conflicting public session hash')
    return values.pop()


def expired_session(raw):
    """Narrow documented-style signals; never treat every 403/error as expiry."""
    if not isinstance(raw, dict):
        return False
    if raw.get('error_code') in ('invalid_security_hash', 'expired_security_hash', 'session_expired'):
        return True
    notices = raw.get('notifications', {})
    if not isinstance(notices, dict):
        return False
    for n in notices.values():
        if isinstance(n, dict) and n.get('type') == 'E':
            msg = BeautifulSoup(str(n.get('message', '')), 'lxml').get_text(' ', strip=True).lower()
            if re.search(r'(?:invalid|expired)\s+(?:security[_ ]hash|csrf token)|session (?:has )?expired', msg):
                return True
    return False


class LinellaSession:
    def __init__(self, transport, metrics):
        self.transport = transport
        self.metrics = metrics
        self.security_hash = None
        self.acquired_at = None
        self.lock = asyncio.Lock()

    @property
    def cookies(self):
        return self.transport.client.cookies

    async def _initialize(self, refresh=False):
        self.security_hash = None
        self.acquired_at = None
        if refresh:
            self.metrics['securityHashRefreshes'] += 1
            self.cookies.clear()
        try:
            body = await self.transport.get(BASE)
            token = extract_security_hash(body)
        except (httpx.HTTPError, UnicodeError, ValueError):
            raise SearchError('Public session initialization failed') from None
        self.security_hash = token
        self.acquired_at = datetime.now(timezone.utc)

    async def initialize_session(self):
        async with self.lock:
            if self.security_hash is None:
                await self._initialize()

    async def refresh_security_hash(self):
        async with self.lock:
            await self._initialize(refresh=True)

    async def search_json(self, query, offset, limit):
        # Serialize requests using this session, including a possible refresh.
        async with self.lock:
            if self.security_hash is None:
                await self._initialize()
            for attempt in range(2):
                def counted():
                    self.metrics['searchApiRequests'] += 1
                try:
                    body = await self.transport.request('POST', BASE+'index.php?dispatch=rf_search.search',
                        data={'query': query, 'offset': str(offset), 'limit': str(limit),
                              'security_hash': self.security_hash, 'is_ajax': '1'}, on_request=counted)
                    raw = json.loads(body)
                except (httpx.HTTPError, UnicodeError, ValueError):
                    raise SearchError('Search transport or JSON failure') from None
                if expired_session(raw):
                    if attempt == 0:
                        await self._initialize(refresh=True)
                        continue
                    raise SearchError('Session rejected after one refresh')
                return raw
        raise SearchError('Search failed')
