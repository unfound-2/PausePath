"""Transactional, ordered SQL migrations with checksums; run as a deployment step."""
import hashlib
import os
from pathlib import Path
import psycopg

with psycopg.connect(os.environ['DATABASE_URL']) as conn:
    conn.execute("SELECT pg_advisory_xact_lock(52908131)")
    conn.execute("CREATE TABLE IF NOT EXISTS schema_migrations (name text PRIMARY KEY, sha256 text NOT NULL, applied_at timestamptz DEFAULT now())")
    for path in sorted((Path(__file__).resolve().parents[1] / 'migrations').glob('*.sql')):
        sql = path.read_text()
        digest = hashlib.sha256(sql.encode()).hexdigest()
        previous = conn.execute('SELECT sha256 FROM schema_migrations WHERE name=%s', (path.name,)).fetchone()
        if previous:
            if previous[0] != digest:
                raise RuntimeError('Applied migration changed: ' + path.name)
            continue
        conn.execute(sql)
        conn.execute('INSERT INTO schema_migrations(name,sha256) VALUES (%s,%s)', (path.name,digest))
        print('Applied', path.name)
