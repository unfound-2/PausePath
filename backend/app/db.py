import os
from contextlib import contextmanager
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool
from .database_config import set_search_path

_pool = None

def pool():
    global _pool
    if _pool is None:
        _pool = ConnectionPool(os.environ['DATABASE_URL'], min_size=1, max_size=int(os.environ.get('DB_POOL_MAX_SIZE', '5')),
                               kwargs={'row_factory': dict_row, 'prepare_threshold': None}, timeout=10, open=True)
    return _pool

@contextmanager
def transaction():
    with pool().connection() as conn:
        with conn.transaction():
            set_search_path(conn)
            conn.execute("SET LOCAL statement_timeout = '8s'")
            yield conn
