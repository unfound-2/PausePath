"""Database-first discovery with a durable, bounded shared tile queue.

The free service does not need a second worker instance: reads wake one background
worker, but never wait for Overpass. Database leases survive process suspension.
"""
from concurrent.futures import ThreadPoolExecutor
from math import floor, ceil
from threading import Lock
from types import SimpleNamespace
import logging
from .db import transaction
from .providers import fetch_osm, store_osm

STEP = .02  # 2.2 km north/south; longitude distance shrinks toward the poles.
_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix='osm-cache')
_worker_lock = Lock()
_log = logging.getLogger(__name__)

def tiles_for(bounds):
    xs = range(floor((bounds.west + 180) / STEP + 1e-8), ceil((bounds.east + 180) / STEP - 1e-8))
    ys = range(floor((bounds.south + 90) / STEP + 1e-8), ceil((bounds.north + 90) / STEP - 1e-8))
    return [(x, y) for x in xs for y in ys]

def tile_bounds(x, y):
    return SimpleNamespace(west=round(x*STEP-180, 6), east=round((x+1)*STEP-180, 6),
                           south=round(y*STEP-90, 6), north=round((y+1)*STEP-90, 6))

def wake_worker():
    if _worker_lock.acquire(blocking=False):
        try: _executor.submit(_run_one)
        except Exception:
            _worker_lock.release()
            raise

def _run_one():
    job = None
    try:
        with transaction() as conn:
            # Shared rate budget: at most four tile jobs/minute, across all replicas.
            budget = conn.execute("UPDATE discovery_budget SET next_job_at=now()+interval '15 seconds' WHERE id=1 AND next_job_at<=now() RETURNING id").fetchone()
            if not budget: return
            job = conn.execute('''WITH candidate AS (
                SELECT x,y FROM discovery_tiles WHERE requested_at>now()-interval '10 minutes'
                AND next_attempt_at<=now() AND (fetched_at IS NULL OR fetched_at<now()-interval '7 days')
                ORDER BY CASE WHEN fetched_at IS NULL THEN 0 ELSE 1 END, requested_at DESC,x,y
                FOR UPDATE SKIP LOCKED LIMIT 1)
                UPDATE discovery_tiles t SET state='loading',next_attempt_at=now()+interval '3 minutes'
                FROM candidate c WHERE t.x=c.x AND t.y=c.y RETURNING t.x,t.y,t.attempts''').fetchone()
            if not job: return
            # Stop growing the cache before consuming the free database's entire budget.
            size = conn.execute("SELECT pg_total_relation_size('pois') AS bytes").fetchone()['bytes']
            if size > 250*1024*1024:
                conn.execute("UPDATE discovery_tiles SET state='unavailable',next_attempt_at=now()+interval '1 hour' WHERE x=%s AND y=%s", (job['x'],job['y']))
                return
        # Network access holds no database connection or transaction open.
        elements = fetch_osm(tile_bounds(job['x'], job['y']))
        with transaction() as conn:
            store_osm(conn, elements)
            conn.execute("UPDATE discovery_tiles SET state='ready',fetched_at=now(),attempts=0,next_attempt_at=now()+interval '7 days' WHERE x=%s AND y=%s", (job['x'],job['y']))
    except Exception:
        _log.warning('Background amenity tile load failed; retained saved facilities')
        if job:
            try:
                with transaction() as conn:
                    conn.execute("UPDATE discovery_tiles SET state='unavailable',attempts=least(attempts+1,6),next_attempt_at=now()+make_interval(secs => %s) WHERE x=%s AND y=%s",
                                 (min(60*2**job['attempts'],1800),job['x'],job['y']))
            except Exception: _log.warning('Tile retry could not be recorded; lease will expire')
    finally:
        _worker_lock.release()

def search_area(bounds):
    tiles = tiles_for(bounds)
    with transaction() as conn:
        # Serialize admission only; keep the durable queue bounded on the free plan.
        conn.execute('SELECT pg_advisory_xact_lock(52908132)')
        count = conn.execute('SELECT count(*) AS n FROM discovery_tiles').fetchone()['n']
        for x,y in tiles:
            updated = conn.execute('UPDATE discovery_tiles SET requested_at=now() WHERE x=%s AND y=%s RETURNING x', (x,y)).fetchone()
            if not updated and count < 10000:
                conn.execute('INSERT INTO discovery_tiles(x,y) VALUES (%s,%s) ON CONFLICT DO NOTHING', (x,y))
                count += 1
        states = conn.execute('''SELECT x,y,state, fetched_at>now()-interval '7 days' AS fresh
            FROM discovery_tiles WHERE x=ANY(%s) AND y=ANY(%s)''',
            (list({x for x,y in tiles}),list({y for x,y in tiles}))).fetchall()
        complete = len(states)==len(tiles) and all(s['fresh'] for s in states)
        unavailable = len(states)<len(tiles) or any(s['state']=='unavailable' and not s['fresh'] for s in states)
        rows = conn.execute('''SELECT id,source,external_id,name,category,
            ST_AsGeoJSON(geom)::jsonb AS location,is_active,confidence_score,
            operating_hours,attributes,closed_until,source_updated_at
            FROM pois WHERE is_active AND (closed_until IS NULL OR closed_until <= now())
            AND geom && ST_MakeEnvelope(%s,%s,%s,%s,4326)
            ORDER BY row_number() OVER (PARTITION BY category ORDER BY confidence_score DESC,id),category LIMIT 501''',
            (bounds.west,bounds.south,bounds.east,bounds.north)).fetchall()
    wake_worker()
    state = 'ready' if complete else ('unavailable' if unavailable else 'loading')
    warning = None if complete else ('Some facilities are temporarily unavailable. Saved stops remain visible; retry is automatic.' if unavailable else 'Loading facilities for this area. Saved stops are shown now.')
    return {'pois': rows[:500], 'truncated': len(rows)>500, 'warning': warning,
            'loading_state':state, 'retry_after_seconds':15 if state=='loading' else 60,
            'tiles_ready':sum(bool(s['fresh']) for s in states),'tiles_total':len(tiles),
            'attribution': '© OpenStreetMap contributors, ODbL 1.0; PausePath community'}
