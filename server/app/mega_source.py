"""Discover the campaign linked to Linella's advertised period, never a fixed ID."""
import re
import unicodedata
from datetime import datetime, time, timezone
from zoneinfo import ZoneInfo
from urllib.parse import urlsplit, parse_qs
from bs4 import BeautifulSoup
from .parser import BASE, public_url, parse_products, next_page

MONTHS = {name: n for n, name in enumerate(('ianuarie februarie martie aprilie mai iunie '
    'iulie august septembrie octombrie noiembrie decembrie').split(), 1)}


def folded(text):
    return ''.join(c for c in unicodedata.normalize('NFD', text.lower()) if not unicodedata.combining(c))


def period(text):
    text = folded(text)
    matches = re.findall(r'\b(\d{1,2})\s+(' + '|'.join(MONTHS) + r')\s+(\d{4})\b', text)
    if matches:
        days = [datetime(int(y), MONTHS[m], int(d)).date() for d, m, y in matches]
    else:
        days = [datetime(int(y), int(m), int(d)).date()
                for d, m, y in re.findall(r'\b(\d{1,2})[/.](\d{1,2})[/.](\d{4})\b', text)]
    if len(days) != 2 or days[1] < days[0]:
        raise ValueError('Missing, ambiguous or reversed Mega period')
    zone = ZoneInfo('Europe/Chisinau')
    stamp = lambda day, clock: datetime.combine(day, clock, zone).astimezone(timezone.utc).isoformat()
    return dict(id=f'mega:{days[0]}', name='Mega Ofertă', type='mega',
                startDate=days[0].isoformat(), endDate=days[1].isoformat(),
                startDateTime=stamp(days[0], time.min),
                endDateTime=stamp(days[1], time(23, 59, 59, 999000)))


def discover(source):
    candidates = []
    for node in BeautifulSoup(source, 'lxml').select('div.under__title'):
        if 'oferta valabila in perioada' not in folded(node.get_text(' ', strip=True)):
            continue
        link = node.select_one('a.title__goto[href]')
        if link is None:
            raise ValueError('Mega period has no linked product listing')
        candidates.append({**period(node.get_text(' ', strip=True)), 'sourceUrl': public_url(link['href'])})
    if not candidates or any(c != candidates[0] for c in candidates):
        raise ValueError('Current Mega campaign could not be discovered unambiguously')
    return candidates[0]


def promotion_id(source, url):
    doc = BeautifulSoup(source, 'lxml')
    container = doc.select_one('#promotions_view_pagination_contents')
    if container is None:
        raise ValueError('Mega product container missing')
    ids = set()
    for node in container.select('input[name="redirect_url"]'):
        query = parse_qs(urlsplit(public_url(node.get('value', ''), url)).query)
        if query.get('dispatch') == ['promotions.view']:
            ids.update(query.get('promotion_id', []))
    # Context object, not unrelated promotion links or recommendations.
    ids.update(re.findall(r"\bcurrent_promotion_id\s*:\s*['\"]?(\d+)", source))
    query = parse_qs(urlsplit(url).query)
    if query.get('dispatch') == ['promotions.view']:
        ids.update(query.get('promotion_id', []))
    if len(ids) != 1 or not next(iter(ids)).isdigit():
        raise ValueError('Missing or conflicting source promotion ID')
    return ids.pop()


def products(source):
    doc = BeautifulSoup(source, 'lxml')
    container = doc.select_one('#promotions_view_pagination_contents')
    if container is None:
        raise ValueError('Mega product container missing')
    # Adapt only this campaign's markup; category parsing remains unchanged.
    for card in container.select('.ut2-gl__item'):
        for field in ('discounted_price', 'list_price'):
            if card.select_one(f'[id^="sec_{field}_"]') is None:
                node = card.select_one(f'[id^="line_{field}_"]')
                if node:
                    node['id'] = node['id'].replace('line_', 'sec_', 1)
        if card.select_one('[id^="line_discount_value_"]') is None:
            node = card.select_one('[id^="line_discount_update_"]')
            if node and '%' in node.get_text():
                node['id'] = node['id'].replace('line_discount_update_', 'line_discount_value_', 1)
    rows, stats = parse_products(str(container))
    return rows, stats, len(container.select('.ut2-gl__item'))


def campaign_next(source, current, first):
    url = next_page(source, current)
    if url is None:
        return None
    # Listing routes may add /page-N/; query pagination must stay on its route.
    base_path = urlsplit(first).path.rstrip('/')
    path = urlsplit(url).path.rstrip('/')
    if path != base_path and not re.fullmatch(re.escape(base_path) + r'/page-\d+', path):
        raise ValueError('Mega pagination escaped the discovered listing')
    return url
