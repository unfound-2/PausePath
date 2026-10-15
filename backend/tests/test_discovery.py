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
    rows=[]; queries=[]
    class DB:
        def execute(self, sql, params):
            queries.append((sql,params)); return self
        def fetchall(self): return rows
    @contextmanager
    def transaction(): yield DB()
    monkeypatch.setattr(discovery,'transaction',transaction)
    discovery._cached.clear(); discovery._calls.clear()
    return rows,queries

def test_cache_only_hydration_and_always_reads_current_status(database,monkeypatch):
    calls=[]
    monkeypatch.setattr(discovery,'baseline_osm',lambda conn,bounds: calls.append(bounds))
    bounds=IngestRequest(**BOUNDS)
    discovery.search_area(bounds); discovery.search_area(bounds)
    assert len(calls)==1
    assert len(database[1])==2
    sql,params=database[1][0]
    assert 'WHERE is_active' in sql and 'closed_until <= now()' in sql
    assert params==(-87.63,41.88,-87.62,41.89)

def test_provider_outage_and_result_cap(database,monkeypatch):
    def fail(*args): raise HTTPException(502,'offline')
    monkeypatch.setattr(discovery,'baseline_osm',fail)
    database[0].extend([{}]*501)
    result=discovery.search_area(IngestRequest(**BOUNDS))
    assert len(result['pois'])==500 and result['truncated']
    assert 'unavailable' in result['warning']
    assert not discovery._cached

def test_discovery_requires_login_and_small_bounds(monkeypatch):
    client=TestClient(main.app)
    assert client.post('/api/v1/pois/search',json=BOUNDS).status_code==401
    main.app.dependency_overrides[identity]=lambda: {'sub':'test'}
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
