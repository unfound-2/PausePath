"""Identifier-safe schema configuration shared by the API and migration runner."""
import os
from psycopg import sql

def set_search_path(conn):
    schemas = list(dict.fromkeys([os.environ.get('DB_SCHEMA', 'public'),
                                  os.environ.get('DB_EXTENSIONS_SCHEMA', 'public')]))
    conn.execute(sql.SQL('SET LOCAL search_path TO {}').format(
        sql.SQL(', ').join(sql.Identifier(name) for name in schemas)))
