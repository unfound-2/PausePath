"""Exercise the same create/list/invite/join contract used by the iOS app."""
from contextlib import contextmanager
from pathlib import Path
from uuid import uuid4
import os

import psycopg
from psycopg import sql
from psycopg.rows import dict_row
import pytest
from fastapi.testclient import TestClient
from app import main, community_features


@pytest.fixture
def client(monkeypatch):
    previous = main.app.dependency_overrides.copy()
    main.app.dependency_overrides[main.identity] = lambda: {"sub": "creator"}
    monkeypatch.setattr(main, "rate_limit", lambda *args: None)
    try:
        yield TestClient(main.app)
    finally:
        main.app.dependency_overrides.clear()
        main.app.dependency_overrides.update(previous)


@pytest.fixture
def database(monkeypatch):
    url = os.environ.get("TEST_DATABASE_URL") or os.environ.get("SOCIAL_TEST_DATABASE_URL")
    if not url:
        pytest.skip("Requires isolated PostgreSQL; available in GitHub Actions")
    with psycopg.connect(url, row_factory=dict_row) as conn:
        assert conn.execute("SELECT current_database() AS name").fetchone()["name"].endswith("_test")
        schema = "community_test_" + uuid4().hex
        conn.execute(sql.SQL("CREATE SCHEMA {}").format(sql.Identifier(schema)))
        conn.execute(sql.SQL("SET LOCAL search_path TO {}, public").format(sql.Identifier(schema)))
        if os.environ.get("TEST_DATABASE_URL"):
            for migration in sorted((Path(__file__).resolve().parents[1] / "migrations").glob("*.sql")):
                conn.execute(migration.read_text(encoding="utf-8"))
        else:
            from database_fixtures import create_community_schema
            create_community_schema(conn)

        @contextmanager
        def transaction():
            with conn.transaction():
                yield conn

        monkeypatch.setattr(main, "transaction", transaction)
        monkeypatch.setattr(community_features, "transaction", transaction)
        try:
            yield conn
        finally:
            conn.rollback()


@pytest.mark.parametrize("name,username", [
    ("", "Walker"), ("x", "Walker"), ("x" * 61, "Walker"),
    ("My group", ""), ("My group", "x" * 33), (None, "Walker"),
])
def test_invalid_creation_does_not_reach_database(client, monkeypatch, name, username):
    def unexpected_transaction():
        pytest.fail("Invalid inputs must not access the database")
    monkeypatch.setattr(main, "transaction", unexpected_transaction)
    response = client.post("/api/v1/communities", json={"name": name, "display_name": username})
    assert response.status_code == 422


def test_create_returns_code_and_other_user_can_join(client, database):
    response = client.post("/api/v1/communities", json={
        "name": " Weekend walkers ", "display_name": " Alice ",
    })
    assert response.status_code == 200, response.text
    group = response.json()
    assert group["name"] == "Weekend walkers"
    assert group["my_display_name"] == "Alice"
    assert group["member_count"] == 1
    code = group["invite_code"]
    assert 4 <= len(code) <= 12 and code.isalnum() and code == code.upper()
    listed = client.get("/api/v1/communities").json()["communities"]
    assert len(listed) == 1
    assert listed[0]["invite_code"] == code
    assert listed[0]["members"] == ["Alice"]

    main.app.dependency_overrides[main.identity] = lambda: {"sub": "friend"}
    assert client.get("/api/v1/communities").json()["communities"] == []
    for _ in range(2):
        joined = client.post("/api/v1/communities/join", json={
            "invite_code": " " + code.lower() + " ", "display_name": "Bob",
        })
        assert joined.status_code == 200, joined.text
        assert joined.json()["id"] == group["id"]
        assert joined.json()["member_count"] == 2
        assert joined.json()["invite_code"] == code
    assert client.post("/api/v1/communities/username", json={"display_name": "Bobby"}).status_code == 200
    listed = client.get("/api/v1/communities").json()["communities"][0]
    assert listed["my_display_name"] == "Bobby"
    assert listed["members"] == ["Alice", "Bobby"]
    assert client.get(f"/api/v1/communities/{group['id']}/challenges").json() == {"challenges": []}


def test_unknown_code_does_not_create_membership(client, database):
    response = client.post("/api/v1/communities/join", json={
        "invite_code": "BADCODE", "display_name": "Walker",
    })
    assert response.status_code == 404
    assert client.get("/api/v1/communities").json() == {"communities": []}


def group(client):
    response=client.post('/api/v1/communities',json={'name':'Our paths','display_name':'Creator','request_id':str(uuid4())})
    assert response.status_code == 200, response.text
    return response.json()

def test_retry_and_shared_goals(client,database):
    payload={'name':'Our paths','display_name':'Creator','request_id':str(uuid4())}
    a=client.post('/api/v1/communities',json=payload).json()
    b=client.post('/api/v1/communities',json=payload).json()
    assert a['id']==b['id'] and a['invite_code']==b['invite_code']
    task=client.post(f"/api/v1/communities/{a['id']}/challenges",json={'name':'Together','metric':'distance_km','target':50,'shared_goal':True}).json()
    assert client.post(f"/api/v1/challenges/{task['id']}/progress",json={'amount':4}).status_code==200
    main.app.dependency_overrides[main.identity]=lambda:{'sub':'friend'}
    client.post('/api/v1/communities/join',json={'invite_code':a['invite_code'],'display_name':'Friend'})
    client.post(f"/api/v1/challenges/{task['id']}/progress",json={'amount':6})
    summary=client.get(f"/api/v1/communities/{a['id']}/challenges").json()['challenges'][0]
    assert summary['shared_goal'] and summary['group_progress']==10 and summary['my_progress']==6
    assert not summary['can_delete']
    assert client.post(f"/api/v1/communities/{a['id']}/challenges/{task['id']}/delete",json={}).status_code==403

def test_member_permissions_rsvp_feed_and_leave(client,database):
    from datetime import datetime,timedelta,timezone
    g=group(client); base=f"/api/v1/communities/{g['id']}"
    payload={'title':'Weekend walk','meeting_point':'Park gate','route_description':'One loop with a bench break','starts_at':(datetime.now(timezone.utc)+timedelta(days=1)).isoformat(),'request_id':str(uuid4())}
    walk=client.post(base+'/walks',json=payload)
    assert walk.status_code==200,walk.text
    wid=walk.json()['id']
    assert client.post(base+'/walks',json=payload).json()['id']==wid
    main.app.dependency_overrides[main.identity]=lambda:{'sub':'friend'}
    assert client.get(base+'/walks').status_code==403
    assert client.post(base+'/posts',json={'body':'Hi','request_id':str(uuid4())}).status_code==403
    client.post('/api/v1/communities/join',json={'invite_code':g['invite_code'],'display_name':'Friend'})
    for _ in range(2): assert client.post(base+f'/walks/{wid}/rsvp',json={'attending':True}).status_code==200
    assert client.get(base+'/walks').json()['walks'][0]['attendees']==1
    assert client.post(base+'/rename',json={'name':'Not mine'}).status_code==403
    assert client.post(base+f'/walks/{wid}/cancel',json={}).status_code==403
    key=str(uuid4())
    for _ in range(2): assert client.post(base+'/posts',json={'body':'My first milestone!','request_id':key}).status_code==200
    posts=client.get(base+'/posts').json()['posts']; assert len(posts)==1
    pid=posts[0]['id']
    for _ in range(2): client.post(base+f'/posts/{pid}/cheer',json={'cheered':True})
    assert client.get(base+'/posts').json()['posts'][0]['cheers']==1
    assert client.post(base+'/leave',json={}).status_code==200
    assert client.get(base+'/posts').status_code==403
    main.app.dependency_overrides[main.identity]=lambda:{'sub':'creator'}
    assert client.get(base+'/posts').json()['posts']==[]
    assert client.get(base+'/walks').json()['walks'][0]['attendees']==0
    assert client.post(base+'/leave',json={}).status_code==409
    assert client.post(base+'/delete',json={}).status_code==200
    assert client.get('/api/v1/communities').json()['communities']==[]

def test_cancelled_walk_rejects_rsvp(client,database):
    from datetime import datetime,timedelta,timezone
    g=group(client); base=f"/api/v1/communities/{g['id']}"
    result=client.post(base+'/walks',json={'title':'Tomorrow','meeting_point':'Gate','route_description':'Loop','starts_at':(datetime.now(timezone.utc)+timedelta(days=1)).isoformat(),'request_id':str(uuid4())})
    wid=result.json()['id']
    assert client.post(base+f'/walks/{wid}/cancel',json={}).status_code==200
    assert client.post(base+f'/walks/{wid}/rsvp',json={'attending':True}).status_code==409

@pytest.mark.parametrize('endpoint,payload',[
    ('posts',{'body':'','request_id':str(uuid4())}),
    ('posts',{'body':'x'*281,'request_id':str(uuid4())}),
    ('walks',{'title':'Walk','meeting_point':'Gate','route_description':'Loop','starts_at':'bad','request_id':str(uuid4())}),
    ('walks',{'title':'Walk','meeting_point':'Gate','route_description':'Loop','starts_at':'2030-01-01T10:00:00','request_id':str(uuid4())}),
])
def test_invalid_features(client,endpoint,payload):
    assert client.post(f'/api/v1/communities/{uuid4()}/{endpoint}',json=payload).status_code==422


def test_owner_transfer_and_removal(client,database):
    g=group(client); base=f"/api/v1/communities/{g['id']}"
    main.app.dependency_overrides[main.identity]=lambda:{'sub':'friend'}
    client.post('/api/v1/communities/join',json={'invite_code':g['invite_code'],'display_name':'Friend'})
    assert client.get(base+'/members').status_code==200
    main.app.dependency_overrides[main.identity]=lambda:{'sub':'creator'}
    assert len(client.get(base+'/members').json()['members'])==2
    assert client.post(base+'/rename',json={'name':'Renamed paths'}).status_code==200
    assert client.post(base+'/transfer',json={'user_id':'friend'}).status_code==200
    assert client.post(base+'/delete',json={}).status_code==403
    main.app.dependency_overrides[main.identity]=lambda:{'sub':'friend'}
    assert client.post(base+'/members/remove',json={'user_id':'creator'}).status_code==200
    assert len(client.get(base+'/members').json()['members'])==1
    main.app.dependency_overrides[main.identity]=lambda:{'sub':'creator'}
    assert client.get(base+'/walks').status_code==403


def test_group_cards_summarize_next_walk_and_active_goals(client,database):
    from datetime import datetime,timedelta,timezone
    g=group(client); base=f"/api/v1/communities/{g['id']}"
    def goal(name,shared=False):
        response=client.post(base+'/challenges',json={'name':name,'metric':'walks','target':3,'shared_goal':shared,'request_id':str(uuid4())})
        assert response.status_code==200,response.text
        return response.json()['id']
    personal=goal('Personal total'); shared=goal('Shared total',True); archived=goal('Archived goal'); goal('Still active')
    client.post(f'/api/v1/challenges/{personal}/progress',json={'amount':3})
    client.post(f'/api/v1/challenges/{shared}/progress',json={'amount':3})
    client.post(base+f'/challenges/{archived}/archive',json={'archived':True})
    now=datetime.now(timezone.utc)
    def plan(title,hours):
        result=client.post(base+'/walks',json={'title':title,'meeting_point':'Public test gate','route_description':'Test plan','starts_at':(now+timedelta(hours=hours)).isoformat(),'request_id':str(uuid4())})
        assert result.status_code==200,result.text
        return result.json()['id']
    cancelled=plan('Cancelled first',1)
    client.post(base+f'/walks/{cancelled}/cancel',json={})
    next_id=plan('Next public walk',2); plan('Later walk',3)
    summary=client.get('/api/v1/communities').json()['communities'][0]
    assert summary['summary_available'] is True and summary['active_goal_count']==1
    assert summary['next_walk']['id']==next_id and summary['next_walk']['title']=='Next public walk'
    main.app.dependency_overrides[main.identity]=lambda:{'sub':'friend'}
    assert client.get('/api/v1/communities').json()['communities']==[]
    assert client.get(base+'/members').status_code==403
    client.post('/api/v1/communities/join',json={'invite_code':g['invite_code'],'display_name':'Friend'})
    summary=client.get('/api/v1/communities').json()['communities'][0]
    assert summary['active_goal_count']==2
    directory=client.get(base+'/members').json()
    assert directory['viewer_is_owner'] is False and directory['community_name']==g['name']
    assert len(directory['members'])==2
    assert all('user_id' not in person for person in directory['members'])
    assert directory['members'][0]['is_owner'] is True
    assert sum(person['is_self'] for person in directory['members'])==1
    assert len({person['member_id'] for person in directory['members']})==2
    assert client.post(base+'/rename',json={'name':'Not owner'}).status_code==403


@pytest.mark.parametrize('is_owner',[False,True])
def test_member_directory_only_owners_receive_management_ids(client,monkeypatch,is_owner):
    class Rows:
        def fetchall(self):
            return [
                {'user_id':'creator','display_name':'QA owner','community_name':'QA circle','is_owner':True},
                {'user_id':'friend','display_name':'QA member','community_name':'QA circle','is_owner':False},
            ]
    class DB:
        def execute(self,*args): return Rows()
    @contextmanager
    def transaction(): yield DB()
    monkeypatch.setattr(community_features,'transaction',transaction)
    monkeypatch.setattr(community_features,'member',lambda *args:is_owner)
    result=client.get(f'/api/v1/communities/{uuid4()}/members')
    assert result.status_code==200,result.text
    body=result.json()
    assert body['community_name']=='QA circle' and body['viewer_is_owner'] is is_owner
    assert [v['is_owner'] for v in body['members']]==[True,False]
    assert [v['is_self'] for v in body['members']]==[True,False]
    assert all(('user_id' in v) is is_owner for v in body['members'])
    assert all(len(v['member_id'])==64 for v in body['members'])
    assert all('community_name' not in v for v in body['members'])
