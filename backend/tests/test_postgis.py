"""Real database integration tests. Skipped unless TEST_DATABASE_URL names an isolated test DB."""
import json
import os
from pathlib import Path
from uuid import uuid4
import pytest
import psycopg
from psycopg.rows import dict_row
from psycopg import errors
from app.curation import QUERY

@pytest.fixture
def conn():
    url=os.environ.get('TEST_DATABASE_URL')
    if not url: pytest.skip('TEST_DATABASE_URL not configured; PostGIS integration not run')
    with psycopg.connect(url,row_factory=dict_row) as connection:
        database=connection.execute('SELECT current_database() AS name').fetchone()['name']
        assert database.endswith('_test'),'Use an isolated database ending in _test'
        connection.execute(Path(__file__).resolve().parents[1].joinpath('migrations/001_initial.sql').read_text())
        try: yield connection
        finally: connection.rollback()

def poi(conn,x=0,y=0):
    return conn.execute("INSERT INTO pois(source,external_id,category,geom,operating_hours) VALUES ('community',%s,'bench',ST_SetSRID(ST_MakePoint(%s,%s),4326),'\"24/7\"') RETURNING id",(str(uuid4()),x,y)).fetchone()['id']

def vote(conn,poi_id,user,kind):
    conn.execute('INSERT INTO poi_reports(poi_id,user_id,report_type,request_id,payload_hash) VALUES (%s,%s,%s,%s,%s)',(poi_id,user,kind,uuid4(),'test'))

def test_consecutive_negative_votes_deactivate_and_confirm_does_not_restore(conn):
    key=poi(conn)
    for user in ('a','b','c'): vote(conn,key,user,'removed')
    row=conn.execute('SELECT * FROM pois WHERE id=%s',(key,)).fetchone()
    assert row['confidence_score']<.3 and row['is_active'] is False
    vote(conn,key,'d','confirm_exists')
    assert conn.execute('SELECT is_active FROM pois WHERE id=%s',(key,)).fetchone()['is_active'] is False

def test_vote_cooldown(conn):
    key=poi(conn); vote(conn,key,'same-user','confirm_exists')
    with pytest.raises(errors.UniqueViolation):
        with conn.transaction(): vote(conn,key,'same-user','removed')

def test_temporary_closure(conn):
    key=poi(conn); vote(conn,key,'user','temporarily_closed')
    assert conn.execute('SELECT closed_until>now() AS closed FROM pois WHERE id=%s',(key,)).fetchone()['closed']

def test_corridor_and_marker_query_uses_meters(conn):
    from app.geometry import densify
    path,total=densify([(0,0),(.02,0)])
    inside=poi(conn,.01,.0003)
    poi(conn,.01,.002)  # >200m from route, not in the 100m corridor
    rows=conn.execute(QUERY,{'route':json.dumps({'type':'LineString','coordinates':path}),
        'lon':.01,'lat':0,'target':total/2,'projection':'+proj=aeqd +lat_0=0 +lon_0=0.01 +datum=WGS84 +units=m +no_defs',
        'categories':['bench'],'weights':json.dumps({'bench':4}),'wheelchair':False}).fetchall()
    assert len(rows)==1 and rows[0]['id']==inside
    assert abs(rows[0]['marker_m']-total/2)<1
    assert rows[0]['target_distance']<40
    assert abs(rows[0]['score']-4*.6/(1+rows[0]['target_distance']))<1e-8
