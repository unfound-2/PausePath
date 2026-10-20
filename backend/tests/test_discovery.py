from contextlib import contextmanager
import pytest
import httpx
from fastapi import HTTPException
from fastapi.testclient import TestClient
from app import discovery, providers, main
from app.auth import identity
from app.models import IngestRequest

BOUNDS = dict(west=-87.63,south=41.88,east=-87.62,north=41.89)

@pytest.fixture
def database(monkeypatch):
    rows=[]; queries=[]; states=[]
    class DB:
        def execute(self, sql, params=None):
            self.sql=sql
            queries.append((sql,params)); return self
        def fetchone(self):
            if 'count(*)' in self.sql: return {'n': 0}
            return {'x': 1}
        def fetchall(self):
            return states if 'SELECT x,y,state' in self.sql else rows
    @contextmanager
    def transaction(): yield DB()
    monkeypatch.setattr(discovery,'transaction',transaction)
    monkeypatch.setattr(discovery,'wake_worker',lambda: None)
    return rows,queries,states

def test_reads_do_not_wait_for_provider_and_distinguish_empty_loading(database,monkeypatch):
    monkeypatch.setattr(discovery,'fetch_osm',lambda *args: pytest.fail('provider called in read path'))
    result=discovery.search_area(IngestRequest(**BOUNDS))
    assert result['pois']==[] and result['loading_state']=='unavailable'
    sql,params=next((s,p) for s,p in database[1] if 'ST_AsGeoJSON' in s)
    assert 'WHERE is_active' in sql and 'closed_until <= now()' in sql
    assert params==(-87.63,41.88,-87.62,41.89,None,None)

def test_ready_empty_is_distinct_from_pending_and_failed(database):
    bounds=IngestRequest(**BOUNDS)
    database[2].extend(dict(x=x,y=y,state='ready',fresh=True) for x,y in discovery.tiles_for(bounds))
    assert discovery.search_area(bounds)['loading_state']=='ready'
    database[2][0].update(state='loading',fresh=False)
    assert discovery.search_area(bounds)['loading_state']=='loading'
    database[2][0].update(state='unavailable')
    assert discovery.search_area(bounds)['loading_state']=='unavailable'

def test_result_cap_and_shared_grid(database):
    from uuid import UUID
    database[0].extend({'id':UUID(int=i+1)} for i in range(501))
    result=discovery.search_area(IngestRequest(**BOUNDS))
    assert len(result['pois'])==500 and result['truncated']
    assert discovery.tiles_for(IngestRequest(west=0,south=0,east=.02,north=.02))==[(9000,4500)]
    assert discovery.tiles_for(IngestRequest(west=-.02,south=-.02,east=0,north=0))==[(8999,4499)]
    assert len(discovery.tiles_for(IngestRequest(west=.001,south=.001,east=.099,north=.099)))==25

def test_discovery_is_public_and_requires_small_bounds(monkeypatch):
    client=TestClient(main.app)
    monkeypatch.setattr(main,'rate_limit',lambda *args: None)
    monkeypatch.setattr(main,'search_area',lambda bounds: dict(pois=[],truncated=False,warning=None,attribution='OSM'))
    try:
        response=client.post('/api/v1/pois/search',json=BOUNDS)
        assert response.status_code==200
        assert response.headers['cache-control']=='private, no-store'
        assert client.post('/api/v1/pois/search',json={**BOUNDS,'east':1}).status_code==422
    finally: main.app.dependency_overrides.clear()

def test_mapbox_connector_uses_walking_profile_and_both_directions(monkeypatch):
    monkeypatch.delenv('PEDESTRIAN_ROUTER_URL',raising=False)
    monkeypatch.setenv('MAPBOX_ACCESS_TOKEN','test-only')
    calls=[]
    class Client:
        def __init__(self,**kwargs): pass
        def __enter__(self): return self
        def __exit__(self,*args): pass
        def get(self,url,params):
            assert '/mapbox/walking/' in url
            assert params['access_token']=='test-only'
            coordinates=[[float(v) for v in part.split(',')] for part in url.rsplit('/',1)[1].split(';')]
            calls.append(coordinates)
            return httpx.Response(200,json={'code':'Ok','waypoints':[{'location':c} for c in coordinates],
                'routes':[{'distance':10,'geometry':{'type':'LineString','coordinates':coordinates}}]},request=httpx.Request('GET',url))
    monkeypatch.setattr(providers.httpx,'Client',Client)
    result=providers.pedestrian_connector([-87.63,41.88],[-87.6301,41.88],100)
    assert result and len(calls)==2 and calls[0]==list(reversed(calls[1]))

def test_worker_fetches_outside_transaction_and_commits_cache_atomically(monkeypatch):
    active=[]; statements=[]
    class DB:
        def execute(self, sql, params=None):
            self.sql=sql; statements.append(sql); return self
        def fetchone(self):
            if 'UPDATE discovery_budget' in self.sql: return {'id':1}
            if 'WITH candidate' in self.sql: return {'x':9000,'y':4500,'attempts':0}
            if 'pg_total_relation_size' in self.sql: return {'bytes':100}
    @contextmanager
    def tx():
        active.append(True)
        try: yield DB()
        finally: active.pop()
    def fetch(bounds):
        assert not active
        assert bounds.west==0 and bounds.north==.02
        return []
    def store(conn, elements): assert active and elements==[]
    monkeypatch.setattr(discovery,'transaction',tx)
    monkeypatch.setattr(discovery,'fetch_osm',fetch)
    monkeypatch.setattr(discovery,'store_osm',store)
    discovery._worker_lock.acquire()
    discovery._run_one()
    assert not discovery._worker_lock.locked()
    assert any("state='ready'" in s for s in statements)
    assert any('FOR UPDATE SKIP LOCKED' in s for s in statements)


def test_worker_failure_schedules_backoff_without_clearing_pois(monkeypatch):
    statements=[]
    class DB:
        def execute(self, sql, params=None):
            self.sql=sql; statements.append((sql,params)); return self
        def fetchone(self):
            if 'UPDATE discovery_budget' in self.sql: return {'id':1}
            if 'WITH candidate' in self.sql: return {'x':9000,'y':4500,'attempts':2}
            return {'bytes':100}
    @contextmanager
    def tx(): yield DB()
    monkeypatch.setattr(discovery,'transaction',tx)
    def fail(bounds): raise HTTPException(502,'offline')
    monkeypatch.setattr(discovery,'fetch_osm',fail)
    discovery._worker_lock.acquire(); discovery._run_one()
    assert any('make_interval' in s and p[0]==240 for s,p in statements)
    assert not any('DELETE' in s for s,p in statements)
    assert not discovery._worker_lock.locked()


def test_cursor_advances_and_skips_queue_admission(database):
    from uuid import UUID
    from app.models import DiscoveryRequest
    cursor=UUID(int=500)
    discovery.search_area(DiscoveryRequest(**BOUNDS,cursor=cursor))
    assert not any('INSERT INTO discovery_tiles' in sql for sql,_ in database[1])
    assert next(p for sql,p in database[1] if 'ST_AsGeoJSON' in sql)[-2:]==(cursor,cursor)


def test_prefetch_cannot_overwrite_visible_priority(database):
    discovery.search_area(IngestRequest(**BOUNDS))
    prefetch=[sql for sql,_ in database[1] if "interval '5 minutes'" in sql]
    assert prefetch and all('ON CONFLICT DO NOTHING' in sql for sql in prefetch)


def test_worker_drains_without_new_requests(monkeypatch):
    calls=[]
    class Stop:
        def is_set(self): return len(calls)>=3
    class Wake:
        def wait(self,timeout): assert timeout==5
        def clear(self): pass
    monkeypatch.setattr(discovery,'_stop',Stop())
    monkeypatch.setattr(discovery,'_wake',Wake())
    def run():
        calls.append(True)
        discovery._worker_lock.release()
    monkeypatch.setattr(discovery,'_run_one',run)
    discovery._worker_loop()
    assert len(calls)==3


def test_split_checkpoints_commit_and_retry_only_missing_quarter(monkeypatch):
    discovery._parts.clear()
    statements=[]; bounds=[]; failed=[False]
    class DB:
        def execute(self,sql,params=None):
            self.sql=sql; statements.append(sql); return self
        def fetchone(self):
            if 'UPDATE discovery_budget' in self.sql:return {'id':1}
            if 'WITH candidate' in self.sql:return {'x':9000,'y':4500,'attempts':1}
            return {'bytes':100}
    @contextmanager
    def tx():yield DB()
    def fetch(b):
        bounds.append((b.west,b.south,b.east,b.north))
        if len(bounds)==2 and not failed[0]:
            failed[0]=True
            raise HTTPException(502,'offline')
        return []
    monkeypatch.setattr(discovery,'transaction',tx)
    monkeypatch.setattr(discovery,'fetch_osm',fetch)
    monkeypatch.setattr(discovery,'store_osm',lambda *args:None)
    monkeypatch.setattr(discovery,'_degraded_until',0)
    for _ in range(5):
        discovery._worker_lock.acquire(); discovery._run_one()
    assert bounds[1]==bounds[2] and bounds[0] not in bounds[1:]
    assert all(e-w==pytest.approx(.01) and n-s==pytest.approx(.01) for w,s,e,n in bounds)
    assert sum("state='ready'" in sql for sql in statements)==1
    assert not discovery._parts


def test_degraded_admission_queues_only_visible_tiles(database,monkeypatch):
    monkeypatch.setattr(discovery,'_degraded_until',float('inf'))
    bounds=IngestRequest(**BOUNDS)
    discovery.search_area(bounds)
    params=next(p for sql,p in database[1] if 'INSERT INTO discovery_tiles' in sql)
    assert len(params[1])==len(discovery.tiles_for(bounds))
