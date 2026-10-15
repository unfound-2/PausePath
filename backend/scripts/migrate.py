"""Transactional, ordered SQL migrations with checksums; run as a deployment step."""
import hashlib
import os
from pathlib import Path
import psycopg
from psycopg import sql as pgsql
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app.database_config import set_search_path

with psycopg.connect(os.environ.get('MIGRATION_DATABASE_URL') or os.environ['DATABASE_URL'], prepare_threshold=None) as conn:
    conn.execute("SELECT pg_advisory_xact_lock(52908131)")
    schema = os.environ.get('DB_SCHEMA', 'public')
    extensions = os.environ.get('DB_EXTENSIONS_SCHEMA', 'public')
    conn.execute(pgsql.SQL('CREATE SCHEMA IF NOT EXISTS {}').format(pgsql.Identifier(schema)))
    conn.execute(pgsql.SQL('CREATE SCHEMA IF NOT EXISTS {}').format(pgsql.Identifier(extensions)))
    conn.execute(pgsql.SQL('CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA {}').format(pgsql.Identifier(extensions)))
    set_search_path(conn)
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
