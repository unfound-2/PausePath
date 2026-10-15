import os
from contextlib import contextmanager
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

_pool = None

def pool():
    global _pool
    if _pool is None:
        _pool = ConnectionPool(os.environ['DATABASE_URL'], min_size=1, max_size=10,
                               kwargs={'row_factory': dict_row}, timeout=10, open=True)
    return _pool

@contextmanager
def transaction():
    with pool().connection() as conn:
        with conn.transaction():
            conn.execute("SET LOCAL statement_timeout = '8s'")
            yield conn
