"""Challenge API validation plus real-database lifecycle coverage in CI."""
from contextlib import contextmanager
from pathlib import Path
from uuid import uuid4
import os
import pytest
import psycopg
from psycopg.rows import dict_row
from fastapi.testclient import TestClient
from app import main

@pytest.fixture
def client(monkeypatch):
    main.app.dependency_overrides[main.identity] = lambda: {"sub": "member"}
    monkeypatch.setattr(main, "rate_limit", lambda *args: None)
    with TestClient(main.app) as client:
        yield client
    main.app.dependency_overrides.clear()

@pytest.mark.parametrize("value", [None, True, -1, 0, 10001, "3", [], {}])
def test_invalid_targets_rejected_before_database(client, value):
    response = client.post(f"/api/v1/communities/{uuid4()}/challenges", json={"name": "Walk together", "metric": "walks", "target": value})
    assert response.status_code == 422

@pytest.mark.parametrize("value", [None, True, -1, 100001, "3", [], {}])
def test_invalid_progress_rejected_before_database(client, value):
    assert client.post(f"/api/v1/challenges/{uuid4()}/progress", json={"amount": value}).status_code == 422

@pytest.mark.parametrize("metric", ["steps", "", None, [], {}])
def test_invalid_metric_rejected(client, metric):
    assert client.post(f"/api/v1/communities/{uuid4()}/challenges", json={"name": "Walk together", "metric": metric, "target": 3}).status_code == 422

def test_community_routes_require_signin():
    with TestClient(main.app) as client:
        assert client.get('/api/v1/communities').status_code == 401
        assert client.post('/api/v1/communities', json={"name": "Group", "display_name": "Walker"}).status_code == 401
        assert client.get(f'/api/v1/communities/{uuid4()}/challenges').status_code == 401
        assert client.post(f'/api/v1/challenges/{uuid4()}/progress', json={"amount": 1}).status_code == 401

@pytest.fixture
def database(monkeypatch):
    url = os.environ.get('TEST_DATABASE_URL')
    if not url:
        pytest.skip('TEST_DATABASE_URL not configured; real PostgreSQL lifecycle runs in CI')
    with psycopg.connect(url, row_factory=dict_row) as conn:
        assert conn.execute('SELECT current_database() AS name').fetchone()['name'].endswith('_test')
        schema = 'challenge_test_' + uuid4().hex
        conn.execute(f'CREATE SCHEMA {schema}')
        conn.execute(f'SET LOCAL search_path TO {schema}, public')
        migration = Path(__file__).resolve().parents[1] / 'migrations/20261017170000_community_challenges.sql'
        conn.execute(migration.read_text())
        @contextmanager
        def transaction():
            with conn.transaction():
                yield conn
        monkeypatch.setattr(main, 'transaction', transaction)
        try:
            yield conn
        finally:
            conn.rollback()

def test_community_challenge_lifecycle_and_privacy(client, database):
    created = client.post('/api/v1/communities', json={"name": "Walking group", "display_name": "Alice"})
    assert created.status_code == 200
    group = created.json()
    path = f"/api/v1/communities/{group['id']}/challenges"
    task = client.post(path, json={"name": "Three walks", "metric": "walks", "target": 3})
    assert task.status_code == 200
    challenge = task.json()
    progress_path = f"/api/v1/challenges/{challenge['id']}/progress"
    assert client.get(path).json()['challenges'][0]['leaderboard'] == []
    # A non-member cannot see or write the board.
    main.app.dependency_overrides[main.identity] = lambda: {"sub": "other"}
    assert client.get(path).status_code == 403
    assert client.post(progress_path, json={"amount": 9}).status_code == 403
    assert client.post(path, json={"name": "No access", "metric": "walks", "target": 3}).status_code == 403
    # Invite is case insensitive, and joining twice does not duplicate membership.
    for _ in range(2):
        joined = client.post('/api/v1/communities/join', json={"invite_code": group['invite_code'].lower(), "display_name": "Bob"})
        assert joined.status_code == 200 and joined.json()['member_count'] == 2
    assert client.post(progress_path, json={"amount": 3}).status_code == 200
    assert client.post(progress_path, json={"amount": 3}).status_code == 200
    board = client.get(path).json()['challenges'][0]
    assert board['my_progress'] == 3  # Retrying sync replaces, rather than doubles, totals.
    assert board['leaderboard'] == [{"name": "Bob", "amount": 3}]
    main.app.dependency_overrides[main.identity] = lambda: {"sub": "member"}
    client.post(progress_path, json={"amount": 4})
    assert [row['name'] for row in client.get(path).json()['challenges'][0]['leaderboard']] == ['Alice', 'Bob']
    # Opting out deletes only the caller's totals and removes them from the board.
    assert client.post(progress_path + '/delete').status_code == 200
    board = client.get(path).json()['challenges'][0]
    assert board['my_progress'] == 0
    assert board['leaderboard'] == [{"name": "Bob", "amount": 3}]
