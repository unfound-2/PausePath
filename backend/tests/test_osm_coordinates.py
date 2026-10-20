from types import SimpleNamespace
from app import providers


def test_osm_query_keeps_node_coordinates_and_area_centers(monkeypatch):
    stored = []
    def post(url, *, data, **kwargs):
        # Emulate Overpass verbosity: tags-only output omits node coordinates.
        geometry = 'out body center;' in data['data']
        elements = [dict(type='node', id=i, tags={'amenity': category},
                         **({'lat': 41.88, 'lon': -87.62} if geometry else {}))
                    for i, category in enumerate(('bench', 'toilets', 'drinking_water', 'cafe'))]
        elements.append(dict(type='way', id=9, tags={'amenity': 'toilets'},
                             center={'lat': 41.88, 'lon': -87.62}))
        return SimpleNamespace(raise_for_status=lambda: None, json=lambda: {'elements': elements})
    monkeypatch.setattr(providers.httpx, 'post', post)
    class Cursor:
        def __enter__(self): return self
        def __exit__(self,*args): pass
        def executemany(self,sql,rows): stored.extend(rows)
    conn = SimpleNamespace(cursor=Cursor)
    bounds = SimpleNamespace(south=41.87, west=-87.63, north=41.89, east=-87.61)
    assert providers.baseline_osm(conn, bounds) == 5
    assert {row[2] for row in stored} == {'bench', 'toilet', 'drinking_water', 'cafe'}
    assert all(row[3:5] == (-87.62, 41.88) for row in stored)


def test_osm_uses_mirror_on_transport_failure(monkeypatch):
    monkeypatch.delenv('OVERPASS_URL', raising=False)
    calls = []
    def post(url, **kwargs):
        calls.append(url)
        if len(calls) == 1:
            raise providers.httpx.ConnectError('upstream unavailable')
        return SimpleNamespace(raise_for_status=lambda: None, json=lambda: {'elements': []})
    monkeypatch.setattr(providers.httpx, 'post', post)
    assert providers.baseline_osm(None, SimpleNamespace(south=0, west=0, north=.01, east=.01)) == 0
    assert len(calls) == 2 and calls[0] != calls[1]


def test_rate_limit_cools_down_without_hiding_working_mirror(monkeypatch):
    import httpx
    providers._provider_health.clear()
    monkeypatch.delenv('OVERPASS_URL', raising=False)
    calls=[]
    def post(url, **kwargs):
        calls.append(url)
        status=429 if 'mail.ru' in url else 200
        return httpx.Response(status,headers={'Retry-After':'120'},json={'elements':[]},request=httpx.Request('POST',url))
    monkeypatch.setattr(providers.httpx,'post',post)
    bounds=SimpleNamespace(south=0,west=0,north=.01,east=.01)
    providers.fetch_osm(bounds); providers.fetch_osm(bounds)
    assert len(calls)==3 and 'private.coffee' in calls[-1]
    providers._provider_health.clear()


def test_invalid_payload_not_cached_as_empty_and_circuit_recovers(monkeypatch):
    import pytest
    from fastapi import HTTPException
    providers._provider_health.clear()
    monkeypatch.setenv('OVERPASS_URL','https://example.com/interpreter')
    now=[100.0]; calls=[]
    monkeypatch.setattr(providers,'monotonic',lambda:now[0])
    def post(url, **kwargs):
        calls.append(url)
        return SimpleNamespace(raise_for_status=lambda:None,json=lambda: {} if len(calls)<3 else {'elements':[]})
    monkeypatch.setattr(providers.httpx,'post',post)
    bounds=SimpleNamespace(south=0,west=0,north=.01,east=.01)
    for _ in range(3):
        with pytest.raises(HTTPException): providers.fetch_osm(bounds)
    assert len(calls)==2
    now[0]+=61
    assert providers.fetch_osm(bounds)==[] and len(calls)==3
    providers._provider_health.clear()
