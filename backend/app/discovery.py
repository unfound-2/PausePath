"""Bounded read-through OSM discovery. Provider data never overrides community trust."""
from collections import OrderedDict, deque
from threading import Lock
from time import monotonic
from fastapi import HTTPException
from .db import transaction
from .providers import baseline_osm

_lock = Lock()
_cached = OrderedDict()
_calls = deque()

def search_area(bounds):
    warning = None
    key = tuple(round(getattr(bounds, k), 4) for k in ('south', 'west', 'north', 'east'))
    # One upstream request at a time per process; bounded memory and global budget.
    # DB rows are always read fresh, including when upstream hydration is deferred.
    if _lock.acquire(blocking=False):
        try:
            now = monotonic()
            while _calls and now - _calls[0] > 60: _calls.popleft()
            if now - _cached.get(key, -1e9) > 900:
                if len(_calls) >= 4:
                    warning = 'New-area loading is busy. Showing stored stops; refresh shortly.'
                else:
                    _calls.append(now)
                    try:
                        with transaction() as conn: baseline_osm(conn, bounds)
                        _cached[key] = monotonic()
                        _cached.move_to_end(key)
                        while len(_cached) > 256: _cached.popitem(last=False)
                    except HTTPException:
                        warning = 'OSM is unavailable. Showing stored stops; coverage may be incomplete.'
        finally:
            _lock.release()
    else:
        warning = 'New-area loading is busy. Showing stored stops; refresh shortly.'
    with transaction() as conn:
        rows = conn.execute('''SELECT id,source,external_id,name,category,
            ST_AsGeoJSON(geom)::jsonb AS location,is_active,confidence_score,
            operating_hours,attributes,closed_until,source_updated_at
            FROM pois WHERE is_active AND (closed_until IS NULL OR closed_until <= now())
            AND geom && ST_MakeEnvelope(%s,%s,%s,%s,4326)
            ORDER BY confidence_score DESC,id LIMIT 501''',
            (bounds.west,bounds.south,bounds.east,bounds.north)).fetchall()
    return {'pois': rows[:500], 'truncated': len(rows)>500, 'warning': warning,
            'attribution': '© OpenStreetMap contributors, ODbL 1.0; PausePath community'}
