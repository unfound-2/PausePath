"""Contracts and database-backed community creation, retries and membership isolation."""
from contextlib import contextmanager
import os
from pathlib import Path
from uuid import uuid4
import psycopg
from psycopg import errors
from psycopg.rows import dict_row
from fastapi.testclient import TestClient
import pytest
from pydantic import ValidationError
from app import main
from app.models import CommunityCreate, CommunityJoin


def test_community_input_validation_and_normalization():
    body = CommunityCreate(name='  Weekend walkers  ', display_name='  Walker  ')
    assert body.name == 'Weekend walkers' and body.display_name == 'Walker'
    assert CommunityJoin(invite_code=' abcd - 2345 ', display_name='Walker').invite_code == 'ABCD2345'
    for payload in [dict(name=' ', display_name='Walker'), dict(name='Walkers', display_name=' '),
                    dict(name='Walkers', display_name='Walker', user_id='forged')]:
        with pytest.raises(ValidationError): CommunityCreate(**payload)
    with pytest.raises(ValidationError): CommunityJoin(invite_code='https://example.org', display_name='Walker')


def test_community_endpoints_require_authentication():
    client = TestClient(main.app)
    assert client.get('/api/v1/communities').status_code == 401
    assert client.post('/api/v1/communities', json={'name':'Walkers', 'display_name':'Walker'}).status_code == 401
    assert client.post('/api/v1/communities/join', json={'invite_code':'ABCD2345', 'display_name':'Walker'}).status_code == 401


def test_readiness_checks_community_schema_and_returns_recoverable_error(monkeypatch):
    class DB:
        def execute(self, query):
            if 'walking_communities' in query: raise errors.UndefinedTable('test-only missing community schema')
    @contextmanager
    def transaction(): yield DB()
    monkeypatch.setattr(main, 'transaction', transaction)
    result = TestClient(main.app).get('/ready')
    assert result.status_code == 503 and result.headers['Retry-After'] == '30'
    assert 'test-only' not in result.text


@pytest.fixture
def community_api(monkeypatch):
    url = os.environ.get('TEST_DATABASE_URL')
    if not url: pytest.skip('Requires an isolated PostGIS test database')
    with psycopg.connect(url, row_factory=dict_row) as conn:
        assert conn.execute('SELECT current_database() AS name').fetchone()['name'].endswith('_test')
        conn.execute('CREATE SCHEMA community_api_test')
        conn.execute('SET LOCAL search_path TO community_api_test,public')
        for path in sorted((Path(__file__).resolve().parents[1] / 'migrations').glob('*.sql')):
            conn.execute(path.read_text())
        @contextmanager
        def transaction():
            with conn.transaction(): yield conn
        monkeypatch.setattr(main, 'transaction', transaction)
        monkeypatch.setattr(main, 'rate_limit', lambda *args: None)
        current = {'sub':'community-test-owner'}
        main.app.dependency_overrides[main.identity] = lambda: current
        try: yield TestClient(main.app), conn, current
        finally:
            main.app.dependency_overrides.clear()
            conn.rollback()


def create(client, **overrides):
    payload = {'name':'Weekend walkers', 'display_name':'Owner', 'request_id':str(uuid4()), **overrides}
    response = client.post('/api/v1/communities', json=payload)
    assert response.status_code == 200, response.text
    return payload, response.json()


def test_create_and_retry_are_one_atomic_group(community_api):
    client, conn, user = community_api
    payload, group = create(client)
    retry = client.post('/api/v1/communities', json=payload)
    assert retry.status_code == 200 and retry.json() == group
    assert group['members'] == ['Owner'] and group['member_count'] == 1
    assert conn.execute('SELECT count(*) AS n FROM walking_communities').fetchone()['n'] == 1
    assert conn.execute('SELECT count(*) AS n FROM walking_community_members').fetchone()['n'] == 1
    assert client.get('/api/v1/communities').json()['communities'][0]['id'] == group['id']
    conflict = client.post('/api/v1/communities', json={**payload,'name':'Changed request'})
    assert conflict.status_code == 409


def test_join_is_idempotent_and_other_groups_are_private(community_api):
    client, conn, user = community_api
    _, group = create(client)
    user['sub'] = 'community-test-joiner'
    assert client.get('/api/v1/communities').json()['communities'] == []
    assert client.get(f"/api/v1/communities/{group['id']}/challenges").status_code == 403
    payload = {'invite_code':group['invite_code'].lower()[:4]+' - '+group['invite_code'].lower()[4:], 'display_name':'Member', 'request_id':str(uuid4())}
    joined = client.post('/api/v1/communities/join', json=payload)
    assert joined.status_code == 200 and joined.json()['member_count'] == 2
    assert client.post('/api/v1/communities/join', json=payload).json() == joined.json()
    assert conn.execute('SELECT count(*) AS n FROM walking_community_members').fetchone()['n'] == 2
    bad = client.post('/api/v1/communities/join', json={**payload,'invite_code':'NOTFOUND','request_id':str(uuid4())})
    assert bad.status_code == 404


def test_invite_collision_rolls_back_and_can_be_retried(community_api, monkeypatch):
    client, conn, user = community_api
    monkeypatch.setattr(main.secrets, 'choice', lambda alphabet: 'A')
    create(client)
    result = client.post('/api/v1/communities', json={'name':'Second group', 'display_name':'Owner','request_id':str(uuid4())})
    assert result.status_code == 503
    assert conn.execute('SELECT count(*) AS n FROM walking_communities').fetchone()['n'] == 1
    assert conn.execute('SELECT count(*) AS n FROM walking_community_members').fetchone()['n'] == 1


def test_progress_board_is_opt_in_and_membership_is_enforced(community_api):
    client, conn, user = community_api
    _, group = create(client)
    created = client.post(f"/api/v1/communities/{group['id']}/challenges", json={'name':'One walk','metric':'walks','target':1})
    assert created.status_code == 200
    task_id = created.json()['id']
    path = f"/api/v1/communities/{group['id']}/challenges"
    assert client.get(path).json()['challenges'][0]['leaderboard'] == []
    assert client.post(f'/api/v1/challenges/{task_id}/progress', json={'amount':1}).status_code == 200
    task = client.get(path).json()['challenges'][0]
    assert task['my_progress_shared'] is True and task['leaderboard'] == [{'name':'Owner','amount':1}]
    assert client.post(f'/api/v1/challenges/{task_id}/progress/delete').status_code == 200
    assert client.get(path).json()['challenges'][0]['leaderboard'] == []
    user['sub'] = 'community-test-outsider'
    assert client.post(f'/api/v1/challenges/{task_id}/progress', json={'amount':5}).status_code == 403
    assert client.post(path, json={'name':'Not allowed','metric':'walks','target':1}).status_code == 403
