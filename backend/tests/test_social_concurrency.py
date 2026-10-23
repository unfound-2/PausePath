"""Separate transactions exercise locking, not mocked query responses."""
import os
from uuid import uuid4,UUID
from contextlib import contextmanager
from concurrent.futures import ThreadPoolExecutor
import threading
import time
import psycopg
from psycopg import sql
from psycopg.rows import dict_row
import pytest
from fastapi import HTTPException
from app import social,main
from database_fixtures import create_community_schema

@pytest.fixture
def concurrent_database(monkeypatch):
    url=os.environ.get('TEST_DATABASE_URL') or os.environ.get('SOCIAL_TEST_DATABASE_URL')
    if not url: pytest.skip('Requires isolated PostgreSQL')
    with psycopg.connect(url,autocommit=True,row_factory=dict_row) as admin:
        assert admin.execute('SELECT current_database() AS name').fetchone()['name'].endswith('_test')
        schema='social_concurrency_'+uuid4().hex
        admin.execute(sql.SQL('CREATE SCHEMA {}').format(sql.Identifier(schema)))
        try:
            with admin.transaction():
                admin.execute(sql.SQL('SET LOCAL search_path TO {},public').format(sql.Identifier(schema)))
                create_community_schema(admin)
                people=admin.execute("INSERT INTO social_profiles(user_id,username,discoverable) VALUES ('alice','alice',true),('bobby','bobby',true) RETURNING user_id,id").fetchall()
            people={row['user_id']:row['id'] for row in people}
            @contextmanager
            def transaction():
                with psycopg.connect(url,row_factory=dict_row) as conn:
                    with conn.transaction():
                        conn.execute(sql.SQL('SET LOCAL search_path TO {},public').format(sql.Identifier(schema)))
                        conn.execute("SET LOCAL statement_timeout='4s'")
                        yield conn
            monkeypatch.setattr(social,'transaction',transaction)
            monkeypatch.setattr(main,'rate_limit',lambda *a:None)
            yield admin,schema,people,transaction
        finally: admin.execute(sql.SQL('DROP SCHEMA {} CASCADE').format(sql.Identifier(schema)))


def test_reciprocal_requests_are_one_pending_relationship(concurrent_database):
    _,_,people,transaction=concurrent_database
    barrier=threading.Barrier(2)
    def send(user,recipient):
        barrier.wait(timeout=3)
        return social.request_friend(social.Target(person_id=people[recipient]),user={'sub':user})
    with ThreadPoolExecutor(2) as pool:
        a=pool.submit(send,'alice','bobby');b=pool.submit(send,'bobby','alice')
        first=a.result(timeout=6);second=b.result(timeout=6)
    assert first['id']==second['id'] and first['status']==second['status']=='pending'
    with transaction() as conn: assert conn.execute('SELECT count(*) AS n FROM friendships').fetchone()['n']==1


def test_block_racing_request_always_wins(concurrent_database):
    _,_,people,transaction=concurrent_database
    barrier=threading.Barrier(2)
    def send():
        barrier.wait(timeout=3)
        try: social.request_friend(social.Target(person_id=people['bobby']),user={'sub':'alice'})
        except HTTPException as error: assert error.status_code==404
    def block():
        barrier.wait(timeout=3)
        social.block(social.Target(person_id=people['alice']),user={'sub':'bobby'})
    with ThreadPoolExecutor(2) as pool:
        a=pool.submit(send);b=pool.submit(block);a.result(timeout=6);b.result(timeout=6)
    with transaction() as conn:
        assert conn.execute('SELECT count(*) AS n FROM friendships').fetchone()['n']==0
        assert conn.execute('SELECT count(*) AS n FROM user_notifications').fetchone()['n']==0
        assert conn.execute('SELECT count(*) AS n FROM user_blocks').fetchone()['n']==1


def test_disabling_requests_while_sender_waits_is_respected(concurrent_database):
    admin,schema,people,transaction=concurrent_database
    with ThreadPoolExecutor(1) as pool:
        with admin.transaction():
            admin.execute(sql.SQL('SET LOCAL search_path TO {},public').format(sql.Identifier(schema)))
            admin.execute("UPDATE social_profiles SET allow_requests=false WHERE user_id='bobby'")
            pending=pool.submit(social.request_friend,social.Target(person_id=people['bobby']),{'sub':'alice'})
            # Wait until the request reaches its target-row lock, then commit the opt-out.
            deadline=time.monotonic()+2
            while time.monotonic()<deadline:
                admin.execute('SELECT pg_stat_clear_snapshot()')
                waiting=admin.execute("SELECT 1 FROM pg_stat_activity WHERE pid<>pg_backend_pid() AND wait_event_type='Lock' AND query LIKE 'SELECT * FROM social_profiles WHERE id=%%'").fetchone()
                if waiting: break
                time.sleep(0.01)
            assert waiting, 'Request did not reach the expected lock'
        with pytest.raises(HTTPException) as failure: pending.result(timeout=6)
        assert failure.value.status_code==404
    with transaction() as conn: assert conn.execute('SELECT count(*) AS n FROM friendships').fetchone()['n']==0
