"""Real PostgreSQL, isolated-schema tests of the social API authorization boundary.

TEST_DATABASE_URL uses the CI PostGIS service. SOCIAL_TEST_DATABASE_URL may use
vanilla PostgreSQL locally: only non-spatial community migrations are required.
No fixture accepts a database whose name does not end in _test.
"""
import os
from contextlib import contextmanager
from pathlib import Path
from datetime import datetime,timedelta,timezone
from uuid import uuid4
import psycopg
from psycopg import sql
from psycopg.rows import dict_row
import pytest
from fastapi.testclient import TestClient
from app import main, social, community_features

BASE='/api/v1/social'

@pytest.fixture
def client(monkeypatch):
    previous=main.app.dependency_overrides.copy()
    main.app.dependency_overrides[main.identity]=lambda:{'sub':'alice'}
    monkeypatch.setattr(main,'rate_limit',lambda *a:None)
    try: yield TestClient(main.app)
    finally:
        main.app.dependency_overrides.clear();main.app.dependency_overrides.update(previous)

@pytest.fixture
def database(monkeypatch):
    url=os.environ.get('TEST_DATABASE_URL') or os.environ.get('SOCIAL_TEST_DATABASE_URL')
    if not url: pytest.skip('Requires isolated PostgreSQL')
    with psycopg.connect(url,row_factory=dict_row) as conn:
        assert conn.execute('SELECT current_database() AS name').fetchone()['name'].endswith('_test')
        schema='social_test_'+uuid4().hex
        conn.execute(sql.SQL('CREATE SCHEMA {}').format(sql.Identifier(schema)))
        conn.execute(sql.SQL('SET LOCAL search_path TO {},public').format(sql.Identifier(schema)))
        conn.execute(sql.SQL("ALTER DEFAULT PRIVILEGES IN SCHEMA {} GRANT ALL ON TABLES TO PUBLIC").format(sql.Identifier(schema)))
        from database_fixtures import create_community_schema
        create_community_schema(conn)
        @contextmanager
        def transaction():
            with conn.transaction(): yield conn
        for module in (main,social,community_features): monkeypatch.setattr(module,'transaction',transaction)
        try: yield conn
        finally: conn.rollback()


def as_user(name): main.app.dependency_overrides[main.identity]=lambda:{'sub':name}

def profile(client,name,**preferences):
    as_user(name)
    response=client.post(BASE+'/profile',json={'username':name,**preferences})
    assert response.status_code==200,response.text
    return response.json()

def friends(client):
    a=profile(client,'alice',discoverable=True);b=profile(client,'bobby',discoverable=True)
    as_user('alice'); request=client.post(BASE+'/friends',json={'person_id':b['id']})
    assert request.status_code==200,request.text
    as_user('bobby');assert client.post(BASE+'/friends/'+request.json()['id'],json={'action':'accept'}).status_code==200
    return a,b,request.json()['id']

def planned_walk(client):
    as_user('alice')
    group=client.post('/api/v1/communities',json={'name':'Park group','display_name':'Alice'}).json()
    route={'title':'Park loop','geometry':{'type':'LineString','coordinates':[[-95.4,29.7],[-95.401,29.701]]},'stops':[{'name':'Bench','category':'bench','location':{'type':'Point','coordinates':[-95.4005,29.7005]}}],'distance_meters':250,'estimated_seconds':300}
    body={'title':'Saturday walk','meeting_point':'Park gate','route_description':'One pause','starts_at':(datetime.now(timezone.utc)+timedelta(days=1)).isoformat(),'request_id':str(uuid4()),'route_snapshot':route,'meeting_location':{'type':'Point','coordinates':[-95.4,29.7]}}
    response=client.post(f"/api/v1/communities/{group['id']}/walks",json=body)
    assert response.status_code==200,response.text
    return group,response.json(),body


def test_opt_in_search_omits_account_ids_and_blocks(client,database):
    alice=profile(client,'alice');bobby=profile(client,'bobby')
    as_user('alice');assert client.get(BASE+'/search',params={'q':'bob'}).json()=={'people':[]}
    profile(client,'bobby',discoverable=True);as_user('alice')
    result=client.get(BASE+'/search',params={'q':'bob'}).json()['people']
    assert result==[{'id':bobby['id'],'username':'bobby'}]
    assert client.post(BASE+'/blocks',json={'person_id':bobby['id']}).status_code==200
    assert client.get(BASE+'/search',params={'q':'bob'}).json()['people']==[]
    as_user('bobby');assert client.get(BASE+'/search',params={'q':'ali'}).json()['people']==[]
    assert client.post(BASE+'/friends',json={'person_id':alice['id']}).status_code==404


def test_mutual_consent_retry_and_third_account_permissions(client,database):
    a=profile(client,'alice',discoverable=True); b=profile(client,'bobby',discoverable=True)
    as_user('alice');r=client.post(BASE+'/friends',json={'person_id':b['id']}).json()
    assert client.post(BASE+'/friends',json={'person_id':b['id']}).json()['id']==r['id']
    assert client.post(BASE+'/friends/'+r['id'],json={'action':'accept'}).status_code==403
    profile(client,'carol')
    assert client.post(BASE+'/friends/'+r['id'],json={'action':'accept'}).status_code==404
    as_user('bobby')
    reverse=client.post(BASE+'/friends',json={'person_id':a['id']}).json()
    assert reverse['id']==r['id'] and reverse['status']=='pending'
    for _ in range(2): assert client.post(BASE+'/friends/'+r['id'],json={'action':'accept'}).status_code==200
    entries=client.get(BASE+'/friends').json()['friends']
    assert len(entries)==1 and entries[0]['status']=='accepted' and 'requester' not in entries[0]
    as_user('alice');assert len(client.get(BASE+'/inbox').json()['notifications'])==1


def test_block_removes_friendship_invites_and_notifications(client,database):
    a,b,key=friends(client);g,w,_=planned_walk(client)
    assert client.post(BASE+f"/walks/{w['id']}/invite",json={'person_id':b['id']}).status_code==200
    as_user('bobby');assert len(client.get(BASE+'/invitations').json()['invitations'])==1
    invite=client.get(BASE+'/invitations').json()['invitations'][0]
    assert client.post(BASE+'/blocks',json={'person_id':a['id']}).status_code==200
    assert client.get(BASE+'/friends').json()['friends']==[]
    assert client.get(BASE+'/invitations').json()['invitations']==[]
    assert client.get(BASE+'/inbox').json()['notifications']==[]
    as_user('alice');assert client.post(BASE+f"/walks/{w['id']}/invite",json={'person_id':b['id']}).status_code==404
    as_user('bobby');assert client.post(BASE+f"/blocks/{a['id']}/remove",json={}).status_code==200
    assert client.get(BASE+'/friends').json()['friends']==[]
    assert client.post(BASE+f"/invitations/{invite['id']}",json={'accept':True}).json()['status']=='declined'


def test_invitation_requires_friend_and_explicit_group_join(client,database):
    a,b,_=friends(client);g,w,payload=planned_walk(client)
    assert client.post(f"/api/v1/communities/{g['id']}/walks",json=payload).json()['id']==w['id']
    payload['route_snapshot']['title']='Changed'
    assert client.post(f"/api/v1/communities/{g['id']}/walks",json=payload).status_code==409
    for _ in range(2): assert client.post(BASE+f"/walks/{w['id']}/invite",json={'person_id':b['id']}).status_code==200
    as_user('bobby');assert client.get(f"/api/v1/communities/{g['id']}/walks").status_code==403
    invite=client.get(BASE+'/invitations').json()['invitations'][0]
    assert 'route_snapshot' not in invite and 'meeting_location' not in invite
    for _ in range(2): assert client.post(BASE+f"/invitations/{invite['id']}",json={'accept':True}).json()['status']=='accepted'
    walks=client.get(f"/api/v1/communities/{g['id']}/walks").json()['walks']
    assert walks[0]['attending'] and walks[0]['attendees']==1
    assert walks[0]['route_snapshot']['title']=='Park loop'
    assert len(client.get(BASE+'/reminders').json()['walks'])==1
    profile(client,'carol');assert client.post(BASE+f"/invitations/{invite['id']}",json={'accept':True}).status_code==404
    assert client.post(BASE+f"/walks/{w['id']}/invite",json={'person_id':b['id']}).status_code==403


def test_notification_preferences_and_read_receipts_are_scoped(client,database):
    a,b,_=friends(client);g,w,_=planned_walk(client)
    as_user('bobby');client.post('/api/v1/communities/join',json={'invite_code':g['invite_code'],'display_name':'Bobby'})
    profile(client,'bobby',notify_goals=False)
    as_user('alice');client.post(f"/api/v1/communities/{g['id']}/challenges",json={'name':'Our goal','metric':'walks','target':3,'request_id':str(uuid4())})
    as_user('bobby');assert not any(n['category']=='goals' for n in client.get(BASE+'/inbox').json()['notifications'])
    own=client.get(BASE+'/inbox').json()['notifications'][0]['id']
    as_user('alice');client.post(BASE+'/inbox/read',json={'ids':[own]})
    as_user('bobby');assert client.get(BASE+'/inbox').json()['notifications'][0]['read_at'] is None
    client.post(BASE+'/inbox/read',json={'ids':[own]})
    assert client.get(BASE+'/inbox').json()['notifications'][0]['read_at'] is not None


def test_cancellation_removes_reminder_and_notifies_once(client,database):
    friends(client);g,w,_=planned_walk(client)
    as_user('bobby');client.post('/api/v1/communities/join',json={'invite_code':g['invite_code'],'display_name':'Bobby'})
    path=f"/api/v1/communities/{g['id']}/walks/{w['id']}"
    client.post(path+'/rsvp',json={'attending':True})
    assert len(client.get(BASE+'/reminders').json()['walks'])==1
    as_user('alice')
    for _ in range(2): assert client.post(path+'/cancel',json={}).status_code==200
    as_user('bobby');assert client.get(BASE+'/reminders').json()['walks']==[]
    alerts=[n for n in client.get(BASE+'/inbox').json()['notifications'] if 'cancelled' in n['message']]
    assert len(alerts)==1


def test_disabled_requests_reject_pending_accept_and_new_requests(client,database):
    a=profile(client,'alice',discoverable=True);b=profile(client,'bobby',discoverable=True)
    as_user('alice');r=client.post(BASE+'/friends',json={'person_id':b['id']}).json()
    profile(client,'bobby',discoverable=True,allow_requests=False)
    assert client.post(BASE+'/friends/'+r['id'],json={'action':'accept'}).status_code==404
    as_user('alice');assert client.post(BASE+'/friends',json={'person_id':b['id']}).status_code==404


def test_schema_is_api_only_and_inbox_is_bounded(client,database):
    profile(client,'alice');profile(client,'bobby')
    names=['social_profiles','friendships','user_blocks','walk_invitations','user_notifications']
    rows=database.execute('SELECT relname,relrowsecurity FROM pg_class WHERE relnamespace=current_schema()::regnamespace AND relname=ANY(%s)',(names,)).fetchall()
    assert len(rows)==5 and all(row['relrowsecurity'] for row in rows)
    public_grants=database.execute('''SELECT c.relname FROM pg_class c CROSS JOIN LATERAL aclexplode(coalesce(c.relacl,acldefault('r',c.relowner))) a
        WHERE c.relnamespace=current_schema()::regnamespace AND c.relname=ANY(%s) AND a.grantee=0''',(names,)).fetchall()
    assert public_grants==[], 'Migration must revoke even inherited PUBLIC table privileges'
    for _ in range(205): social.notify(database,'bobby','alice','invites','Test notification')
    assert database.execute("SELECT count(*) AS n FROM user_notifications WHERE user_id='bobby'").fetchone()['n']==200

@pytest.mark.parametrize('payload',[{'username':'A'}, {'username':'../alice'}, {'username':'alice','discoverable':'yes'}, {'username':'alice','notify_goals':1}])
def test_profile_validation(client,payload):
    assert client.post(BASE+'/profile',json=payload).status_code==422


def test_untrusted_snapshot_is_bounded(client):
    from app.models import SharedRouteSnapshot
    from pydantic import ValidationError
    with pytest.raises(ValidationError):
        SharedRouteSnapshot.model_validate({'title':'Bad','geometry':{'type':'LineString','coordinates':[[999,99],[0,0]]},'distance_meters':300,'estimated_seconds':300})
    with pytest.raises(ValidationError):
        SharedRouteSnapshot.model_validate({'title':'Bad','geometry':{'type':'LineString','coordinates':[[0,0],[1,1]]},'distance_meters':300,'estimated_seconds':300,'health':{'heart_rate':100}})


def test_shared_goal_completion_notifies_once_even_after_progress_correction(client,database):
    friends(client);g,w,_=planned_walk(client)
    as_user('bobby');client.post('/api/v1/communities/join',json={'invite_code':g['invite_code'],'display_name':'Bobby'})
    as_user('alice'); goal=client.post(f"/api/v1/communities/{g['id']}/challenges",json={'name':'Shared walks','metric':'walks','target':3,'shared_goal':True,'request_id':str(uuid4())}).json()
    for amount in (3,3,1,4):
        r=client.post(f"/api/v1/challenges/{goal['id']}/progress",json={'amount':amount})
        assert r.status_code==200,r.text
    as_user('bobby');notes=client.get(BASE+'/inbox').json()['notifications']
    assert len([n for n in notes if 'reached its target' in n['message']])==1
    assert all('amount' not in n and 'user_id' not in n for n in notes)


def test_notification_settings_do_not_change_discoverability(client,database):
    profile(client,'alice',discoverable=True)
    assert client.post(BASE+'/notification-preferences',json={'notify_invites':False,'notify_walks':True,'notify_goals':False}).status_code==200
    me=client.get(BASE+'/profile').json()['profile']
    assert me['discoverable'] and not me['notify_invites'] and not me['notify_goals']


def test_removing_friend_cancels_unaccepted_invitation(client,database):
    a,b,key=friends(client);g,w,_=planned_walk(client)
    client.post(BASE+f"/walks/{w['id']}/invite",json={'person_id':b['id']})
    as_user('bobby');invite=client.get(BASE+'/invitations').json()['invitations'][0]
    as_user('alice');assert client.post(BASE+'/friends/'+key,json={'action':'remove'}).status_code==200
    as_user('bobby');assert client.get(BASE+'/invitations').json()['invitations']==[]
    assert client.post(BASE+f"/invitations/{invite['id']}",json={'accept':True}).json()['status']=='declined'


def test_social_routes_require_authentication(client):
    main.app.dependency_overrides.clear()
    for path in ('profile','friends','search?q=alice','inbox','invitations','reminders','blocks'):
        assert client.get(BASE+'/'+path).status_code==401


def test_literal_username_prefix_and_case_validation(client,database):
    profile(client,'alice',discoverable=True);profile(client,'bob_a',discoverable=True);profile(client,'bobby',discoverable=True)
    as_user('alice')
    rows=client.get(BASE+'/search',params={'q':'bob_'}).json()['people']
    assert [row['username'] for row in rows]==['bob_a']
    assert client.get(BASE+'/search',params={'q':'Bob'}).status_code==422


def test_unavailable_invitation_cannot_join_or_leak_group_plan(client,database):
    a,b,_=friends(client);g,w,_=planned_walk(client)
    client.post(BASE+f"/walks/{w['id']}/invite",json={'person_id':b['id']})
    as_user('bobby');invite=client.get(BASE+'/invitations').json()['invitations'][0]
    as_user('alice');client.post(f"/api/v1/communities/{g['id']}/walks/{w['id']}/cancel",json={})
    as_user('bobby')
    assert client.post(BASE+f"/invitations/{invite['id']}",json={'accept':True}).status_code==409
    assert client.get(f"/api/v1/communities/{g['id']}/walks").status_code==403


def test_privacy_defaults_and_owner_only_settings(client,database):
    alice=profile(client,'alice')
    assert alice['discoverable'] is False and 'user_id' not in alice
    profile(client,'bobby')
    assert client.post(BASE+'/profile',json={'username':'alice'}).status_code==409
    assert client.get(BASE+'/profile').json()['profile']['username']=='bobby'
