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
    conn = SimpleNamespace(execute=lambda sql, params: stored.append(params))
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
