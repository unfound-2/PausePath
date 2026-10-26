"""Account deletion: data removal, ownership hand-off, idempotent retries."""
import os
from contextlib import contextmanager
from uuid import uuid4
import httpx
import psycopg
from psycopg import sql
from psycopg.rows import dict_row
import pytest
from fastapi.testclient import TestClient
from app import main, social, community_features, account

SOCIAL = '/api/v1/social'


@pytest.fixture
def database(monkeypatch):
    url = os.environ.get('TEST_DATABASE_URL') or os.environ.get('SOCIAL_TEST_DATABASE_URL')
    if not url: pytest.skip('Requires isolated PostgreSQL')
    with psycopg.connect(url, row_factory=dict_row) as conn:
        assert conn.execute('SELECT current_database() AS name').fetchone()['name'].endswith('_test')
        schema = 'account_test_' + uuid4().hex
        conn.execute(sql.SQL('CREATE SCHEMA {}').format(sql.Identifier(schema)))
        conn.execute(sql.SQL('SET LOCAL search_path TO {},public').format(sql.Identifier(schema)))
        from database_fixtures import create_community_schema
        create_community_schema(conn)
        # Non-spatial stand-ins for the PostGIS-backed stop tables.
        conn.execute('''CREATE TABLE pois (id uuid PRIMARY KEY, recomputed int NOT NULL DEFAULT 0);
            CREATE TABLE poi_reports (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), poi_id uuid REFERENCES pois(id), user_id text NOT NULL);
            CREATE TABLE poi_suggestions (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id text NOT NULL, status text NOT NULL);
            CREATE TABLE api_rate_buckets (user_id text, action text, window_start timestamptz, count int);
            CREATE FUNCTION update_poi_confidence(target uuid) RETURNS void LANGUAGE sql AS
              $$ UPDATE pois SET recomputed=recomputed+1 WHERE id=target $$;''')
        @contextmanager
        def transaction():
            with conn.transaction(): yield conn
        for module in (main, social, community_features, account): monkeypatch.setattr(module, 'transaction', transaction)
        try: yield conn
        finally: conn.rollback()


@pytest.fixture
def client(monkeypatch):
    previous = main.app.dependency_overrides.copy()
    monkeypatch.setattr(main, 'rate_limit', lambda *a: None)
    monkeypatch.setenv('SUPABASE_URL', 'https://example.supabase.co')
    monkeypatch.setenv('SUPABASE_SERVICE_ROLE_KEY', 'service-key')
    deleted = []
    monkeypatch.setattr(account, 'delete_auth_user', deleted.append)
    try:
        test = TestClient(main.app); test.deleted = deleted; yield test
    finally:
        main.app.dependency_overrides.clear(); main.app.dependency_overrides.update(previous)


def as_user(name): main.app.dependency_overrides[main.identity] = lambda: {'sub': name}


def community(client, owner, *members):
    as_user(owner)
    created = client.post('/api/v1/communities', json={'name': 'Morning loop', 'display_name': owner})
    assert created.status_code == 200, created.text
    for name in members:
        as_user(name)
        assert client.post('/api/v1/communities/join', json={'invite_code': created.json()['invite_code'], 'display_name': name}).status_code == 200
    return created.json()['id']


def test_deletion_removes_personal_rows_and_hands_off_communities(client, database):
    shared = community(client, 'alice', 'bobby', 'carol')
    solo = community(client, 'alice')
    as_user('alice')
    assert client.post(f'/api/v1/communities/{shared}/posts', json={'body': 'Hi', 'request_id': str(uuid4())}).status_code == 200
    goal = client.post(f'/api/v1/communities/{shared}/challenges', json={'name': 'Ten walks', 'metric': 'walks', 'target': 10})
    assert client.post(f'/api/v1/challenges/{goal.json()["id"]}/progress', json={'amount': 3}).status_code == 200
    assert client.post(SOCIAL + '/profile', json={'username': 'alice'}).status_code == 200
    poi = uuid4()
    database.execute('INSERT INTO pois(id) VALUES (%s)', (poi,))
    database.execute("INSERT INTO poi_reports(poi_id,user_id) VALUES (%s,'alice'),(%s,'bobby')", (poi, poi))
    database.execute("INSERT INTO poi_suggestions(user_id,status) VALUES ('alice','pending'),('alice','approved')")
    database.execute("INSERT INTO api_rate_buckets VALUES ('alice','x',now(),1)")

    response = client.post('/api/v1/account/delete', json={})
    assert response.status_code == 200, response.text
    assert response.json() == {'deleted': True, 'apple_revoked': False}
    assert client.deleted == ['alice']

    one = lambda query, *args: database.execute(query, args).fetchone()
    assert one('SELECT created_by FROM walking_communities WHERE id=%s', shared)['created_by'] == 'bobby'
    assert one('SELECT 1 AS x FROM walking_communities WHERE id=%s', solo) is None
    for table, column in [('walking_community_members', 'user_id'), ('walking_challenge_progress', 'user_id'),
                          ('community_posts', 'user_id'), ('social_profiles', 'user_id'), ('poi_reports', 'user_id'),
                          ('api_request_receipts', 'user_id'), ('api_rate_buckets', 'user_id'), ('walking_challenges', 'created_by')]:
        assert one(f"SELECT count(*) AS n FROM {table} WHERE {column}='alice'")['n'] == 0, table
    assert one('SELECT created_by FROM walking_challenges WHERE id=%s', goal.json()['id'])['created_by'] == account.DELETED_SUBJECT
    assert one("SELECT count(*) AS n FROM poi_reports WHERE user_id='bobby'")['n'] == 1
    assert one('SELECT recomputed FROM pois WHERE id=%s', poi)['recomputed'] == 1
    assert one("SELECT status FROM poi_suggestions WHERE user_id=%s", account.DELETED_SUBJECT)['status'] == 'approved'

    # A retry after a lost response succeeds without touching anyone else.
    assert client.post('/api/v1/account/delete', json={}).status_code == 200
    assert one("SELECT count(*) AS n FROM walking_community_members WHERE community_id=%s", shared)['n'] == 2


def test_deletion_refuses_before_touching_data_when_unconfigured(client, database, monkeypatch):
    community(client, 'alice')
    monkeypatch.delenv('SUPABASE_SERVICE_ROLE_KEY')
    as_user('alice')
    assert client.post('/api/v1/account/delete', json={}).status_code == 503
    assert database.execute("SELECT count(*) AS n FROM walking_community_members WHERE user_id='alice'").fetchone()['n'] == 1
    assert client.deleted == []


def test_auth_failure_is_reported_for_retry(client, database, monkeypatch):
    def fail(subject): raise httpx.ConnectError('down')
    monkeypatch.setattr(account, 'delete_auth_user', fail)
    as_user('alice')
    response = client.post('/api/v1/account/delete', json={})
    assert response.status_code == 502


def test_apple_revocation_is_skipped_without_credentials(monkeypatch):
    for name in ('APPLE_TEAM_ID', 'APPLE_KEY_ID', 'APPLE_CLIENT_ID', 'APPLE_PRIVATE_KEY'):
        monkeypatch.delenv(name, raising=False)
    assert account.revoke_apple('code') is False
    assert account.revoke_apple(None) is False


def test_deletion_requires_sign_in():
    main.app.dependency_overrides.pop(main.identity, None)
    assert TestClient(main.app).post('/api/v1/account/delete', json={}).status_code == 401
