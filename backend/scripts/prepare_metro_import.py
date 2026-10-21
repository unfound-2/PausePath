"""Prepare bounded, idempotent SQL batches from a completed metro snapshot.

Uses the API's OSM normalization and conflict policy, including preservation of
community status and reviewed attributes. Execute batches in order using an
administrative database connection. No credentials are embedded in the output.
"""
import argparse
import json
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app.providers import store_osm


class Capture:
    def cursor(self): return self
    def __enter__(self): return self
    def __exit__(self, *args): pass
    def executemany(self, sql, rows): self.sql, self.rows = sql, rows


def prepare(snapshot, output):
    data = json.loads(snapshot.read_text())
    if not data.get('complete') or not isinstance(data.get('elements'), list):
        raise ValueError('Only complete snapshots can be imported')
    capture = Capture()
    store_osm(capture, data['elements'])
    rows = getattr(capture, 'rows', [])
    conflict = capture.sql.split('ON CONFLICT', 1)[1] if rows else ''
    output.mkdir(parents=True, exist_ok=True)
    for offset in range(0, len(rows), 300):
        payload = [dict(zip(('external_id','name','category','lon','lat','operating_hours','attributes'),
                   [v.obj if hasattr(v, 'obj') else v for v in row])) for row in rows[offset:offset+300]]
        # SQL string literal escaping; public OSM text must never become SQL code.
        literal = json.dumps(payload, ensure_ascii=True).replace("'", "''")
        sql = """BEGIN;
SET LOCAL search_path = pausepath, extensions, public;
SET LOCAL statement_timeout = '30s';
DO $$ BEGIN
 IF pg_total_relation_size('pausepath.pois') > 250*1024*1024
 OR pg_database_size(current_database()) > 450*1024*1024 THEN
 RAISE EXCEPTION 'Metro preload stopped at storage budget'; END IF;
END $$;
WITH inserted AS (
INSERT INTO pois(source,external_id,name,category,geom,operating_hours,attributes)
SELECT 'osm',external_id,name,category,ST_SetSRID(ST_MakePoint(lon,lat),4326),operating_hours,attributes
FROM jsonb_to_recordset('%s'::jsonb) AS r(external_id text,name text,category text,lon double precision,lat double precision,operating_hours jsonb,attributes jsonb)
ON CONFLICT%s RETURNING id)
SELECT count(*) AS imported FROM inserted;
COMMIT;
""" % (literal, conflict)
        (output / f'{offset//300:04d}.sql').write_text(sql)
    print(json.dumps({'region': data['region'], 'rows': len(rows), 'batches': (len(rows)+299)//300}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('snapshot', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    prepare(args.snapshot, args.output)
