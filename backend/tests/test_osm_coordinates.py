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
