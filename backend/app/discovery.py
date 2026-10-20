"""Database-first discovery with a durable, bounded shared tile queue.

The free service does not need a second worker instance: reads wake one background
worker, but never wait for Overpass. Database leases survive process suspension.
"""
from math import floor, ceil
from threading import Lock, Event, Thread
from types import SimpleNamespace
import logging
from time import monotonic
from .db import transaction
from .providers import fetch_osm, store_osm

STEP = .02  # 2.2 km north/south; longitude distance shrinks toward the poles.
_stop = Event()
_wake = Event()
_thread = None
_active_until = 0.0
_degraded_until = 0.0
# Bounded, process-local checkpoints; successful pieces are already stored in PostGIS.
_parts = {}
_worker_lock = Lock()
_log = logging.getLogger('uvicorn.error')

def tiles_for(bounds):
    xs = range(floor((bounds.west + 180) / STEP + 1e-8), ceil((bounds.east + 180) / STEP - 1e-8))
    ys = range(floor((bounds.south + 90) / STEP + 1e-8), ceil((bounds.north + 90) / STEP - 1e-8))
    return [(x, y) for x in xs for y in ys]

def tile_bounds(x, y):
    return SimpleNamespace(west=round(x*STEP-180, 6), east=round((x+1)*STEP-180, 6),
                           south=round(y*STEP-90, 6), north=round((y+1)*STEP-90, 6))

def start_worker():
    global _thread
    if _thread and _thread.is_alive(): return
    _stop.clear()
    _thread = Thread(target=_worker_loop, name='osm-cache', daemon=True)
    _thread.start()

def stop_worker():
    _stop.set()
    _wake.set()
    if _thread: _thread.join(timeout=2)

def wake_worker():
    global _active_until
    _active_until = monotonic() + 600
    _wake.set()

def _worker_loop():
    # Resume recent durable jobs after restart, then sleep when exploration stops.
    global _active_until
    _active_until = monotonic() + 600
    while not _stop.is_set():
        if monotonic() < _active_until and _worker_lock.acquire(blocking=False):
            _run_one()
        _wake.wait(timeout=5 if monotonic() < _active_until else 60)
        _wake.clear()

def _run_one():
    global _degraded_until
    job = None
    started = monotonic()
    fetched = None
    fetch_started = None
    try:
        with transaction() as conn:
            # Shared rate budget: at most twelve tile jobs/minute, across all replicas.
            budget = conn.execute("UPDATE discovery_budget SET next_job_at=now()+interval '5 seconds' WHERE id=1 AND next_job_at<=now() RETURNING id").fetchone()
            if not budget: return
            job = conn.execute('''WITH candidate AS (
                SELECT x,y FROM discovery_tiles WHERE requested_at>now()-interval '10 minutes'
                AND (%s = false OR requested_at>now()-interval '2 minutes')
                AND next_attempt_at<=now() AND (fetched_at IS NULL OR fetched_at<now()-interval '7 days')
                ORDER BY requested_at DESC, CASE WHEN fetched_at IS NULL THEN 0 ELSE 1 END,x,y
                FOR UPDATE SKIP LOCKED LIMIT 1)
                UPDATE discovery_tiles t SET state='loading',next_attempt_at=now()+interval '3 minutes'
                FROM candidate c WHERE t.x=c.x AND t.y=c.y RETURNING t.x,t.y,t.attempts''', (monotonic() < _degraded_until,)).fetchone()
            if not job: return
            # Stop growing the cache before consuming the free database's entire budget.
            size = conn.execute("SELECT pg_total_relation_size('pois') AS bytes").fetchone()['bytes']
            if size > 250*1024*1024:
                conn.execute("UPDATE discovery_tiles SET state='unavailable',next_attempt_at=now()+interval '1 hour' WHERE x=%s AND y=%s", (job['x'],job['y']))
                return
        # Network access holds no database connection or transaction open.
        fetch_started = monotonic()
        key = (job['x'],job['y'])
        bounds = tile_bounds(*key)
        part = None
        completed = set()
        if job['attempts'] > 0 or key in _parts:
            # Only fetch one missing quarter per job; let other visible tiles run too.
            previous = _parts.get(key)
            if previous and monotonic()-previous[0] < 3600: completed = previous[1].copy()
            part = next(i for i in range(4) if i not in completed)
            mid_lon = (bounds.west+bounds.east)/2
            mid_lat = (bounds.south+bounds.north)/2
            bounds = SimpleNamespace(west=bounds.west if part%2==0 else mid_lon,
                east=mid_lon if part%2==0 else bounds.east,
                south=bounds.south if part<2 else mid_lat,
                north=mid_lat if part<2 else bounds.north)
        elements = fetch_osm(bounds)
        fetched = monotonic()
        if part is not None: completed.add(part)
        complete = part is None or len(completed)==4
        with transaction() as conn:
            store_osm(conn, elements)
            if complete:
                conn.execute("UPDATE discovery_tiles SET state='ready',fetched_at=now(),attempts=0,next_attempt_at=now()+interval '7 days' WHERE x=%s AND y=%s", key)
            else:
                conn.execute("UPDATE discovery_tiles SET state='queued',attempts=greatest(attempts,1),next_attempt_at=now()+interval '5 seconds' WHERE x=%s AND y=%s", key)
        # Record a checkpoint only after the POIs commit successfully.
        if complete: _parts.pop(key, None)
        else:
            if key not in _parts and len(_parts)>=256:
                _parts.pop(min(_parts, key=lambda k: _parts[k][0]))
            _parts[key] = (monotonic(), completed)
    except Exception as error:
        _degraded_until = monotonic() + 300
        _log.warning('Background amenity tile load failed type=%s; saved facilities retained; prefetch paused', type(error).__name__)
        if job:
            try:
                with transaction() as conn:
                    conn.execute("UPDATE discovery_tiles SET state='unavailable',attempts=least(attempts+1,6),next_attempt_at=now()+make_interval(secs => %s) WHERE x=%s AND y=%s",
                                 (min(60*2**job['attempts'],1800),job['x'],job['y']))
            except Exception: _log.warning('Tile retry could not be recorded; lease will expire')
    finally:
        if job:
            _log.info('discovery_job total_ms=%.1f provider_ms=%s store_ms=%s',
                      (monotonic()-started)*1000,
                      round((fetched-fetch_started)*1000,1) if fetched else None,
                      round((monotonic()-fetched)*1000,1) if fetched else None)
        _worker_lock.release()

def search_area(bounds):
    started = monotonic()
    cursor = getattr(bounds, "cursor", None)
    tiles = tiles_for(bounds)
    with transaction() as conn:
        if cursor is None:
            # Serialize short queue admission only, never the spatial read.
            conn.execute('SELECT pg_advisory_xact_lock(52908132)')
            count = conn.execute('SELECT count(*) AS n FROM discovery_tiles').fetchone()['n']
            visible = set(tiles)
            nearby = sorted({(x+dx,y+dy) for x,y in tiles for dx in (-1,0,1) for dy in (-1,0,1)
                             if 0 <= x+dx < 18000 and 250 <= y+dy < 8750} - visible)
            conn.execute("""UPDATE discovery_tiles SET requested_at=now()
                WHERE (x,y) IN (SELECT * FROM unnest(%s::int[],%s::int[]))""",
                ([x for x,y in tiles],[y for x,y in tiles]))
            candidates = tiles + (nearby if monotonic() >= _degraded_until else [])
            # Two batched statements replace dozens of round trips per viewport.
            conn.execute("""INSERT INTO discovery_tiles(x,y,requested_at)
                SELECT q.x,q.y,CASE WHEN q.rank<=%s THEN now() ELSE now()-interval '5 minutes' END
                FROM unnest(%s::int[],%s::int[]) WITH ORDINALITY AS q(x,y,rank)
                WHERE NOT EXISTS (SELECT 1 FROM discovery_tiles t WHERE t.x=q.x AND t.y=q.y)
                ORDER BY q.rank LIMIT %s ON CONFLICT DO NOTHING""",
                (len(tiles),[x for x,y in candidates],[y for x,y in candidates],max(0,10000-count)))
        states = conn.execute('''SELECT x,y,state, fetched_at>now()-interval '7 days' AS fresh
            FROM discovery_tiles WHERE x=ANY(%s) AND y=ANY(%s)''',
            (list({x for x,y in tiles}),list({y for x,y in tiles}))).fetchall()
        complete = len(states)==len(tiles) and all(s['fresh'] for s in states)
        pending = any(s['state'] in ('queued','loading') and not s['fresh'] for s in states)
        unavailable = not pending and (len(states)<len(tiles) or any(s['state']=='unavailable' and not s['fresh'] for s in states))
    with transaction() as conn:
        rows = conn.execute('''SELECT id,source,external_id,name,category,
            ST_AsGeoJSON(geom)::jsonb AS location,is_active,confidence_score,
            operating_hours,attributes,closed_until,source_updated_at
            FROM pois WHERE is_active AND (closed_until IS NULL OR closed_until <= now())
            AND geom && ST_MakeEnvelope(%s,%s,%s,%s,4326)
            AND (%s::uuid IS NULL OR id > %s::uuid)
            ORDER BY id LIMIT 501''',
            (bounds.west,bounds.south,bounds.east,bounds.north,cursor,cursor)).fetchall()
    wake_worker()
    state = 'ready' if complete else ('unavailable' if unavailable else 'loading')
    warning = None if complete else ('Some facilities are temporarily unavailable. Saved stops remain visible; retry is automatic.' if unavailable else 'Loading facilities for this area. Saved stops are shown now.')
    _log.info('discovery_read db_ms=%.1f rows=%d state=%s', (monotonic()-started)*1000,len(rows),state)
    return {'next_cursor':str(rows[499]['id']) if len(rows)>500 else None, 'pois': rows[:500], 'truncated': len(rows)>500, 'warning': warning,
            'loading_state':state, 'retry_after_seconds':5 if state=='loading' else 60,
            'tiles_ready':sum(bool(s['fresh']) for s in states),'tiles_total':len(tiles),
            'attribution': '© OpenStreetMap contributors, ODbL 1.0; PausePath community'}
