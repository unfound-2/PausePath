from contextlib import contextmanager
from fastapi.testclient import TestClient
from fastapi import HTTPException
from starlette.requests import Request
import pytest
from app import main


def test_public_contract_keeps_all_writes_protected():
    client=TestClient(main.app)
    schema=client.get('/openapi.json').json()['paths']
    for path,method in [('/api/v1/pois/search','post'),('/api/v1/pois/{poi_id}','get'),
                        ('/api/v1/routes/curate','post'),('/api/v1/commercial/mapbox/category','post'),
                        ('/api/v1/commercial/mapbox/suggest','post'),('/api/v1/commercial/mapbox/retrieve','post')]:
        assert not schema[path][method].get('security')
    for path,method in [('/api/v1/reports','post'),('/api/v1/admin/ingest/osm','post'),
                        ('/api/v1/pois/{poi_id}/review','patch'),('/api/v1/osm/queue','post')]:
        assert schema[path][method]['security']
    assert client.post('/api/v1/reports',json={'kind':'suggestion','request_id':'00000000-0000-0000-0000-000000000001',
        'category':'bench','location':{'coordinates':[-87.62,41.88]}}).status_code==401


def test_public_peer_identity_ignores_spoofed_forwarding_header():
    def request(ip,header):
        return Request({'type':'http','client':(ip,123),'headers':[(b'x-forwarded-for',header)]})
    first=main.public_reader(request('192.0.2.1',b'1.1.1.1'))
    second=main.public_reader(request('192.0.2.1',b'8.8.8.8'))
    assert first==second
    assert first != main.public_reader(request('192.0.2.2',b'1.1.1.1'))
    assert '192.0.2.1' not in first['sub']
    assert 'roles' not in first


def test_public_limits_enforce_peer_and_shared_budget(monkeypatch):
    counts={}; limit=2
    class DB:
        def execute(self,sql,params):
            key=params
            counts[key]=counts.get(key,0)+1
            self.count=counts[key]
            return self
        def fetchone(self): return {'count':self.count}
    @contextmanager
    def transaction(): yield DB()
    monkeypatch.setattr(main,'transaction',transaction)
    user={'sub':'guest:one','public_read':True}
    main.rate_limit(user,'test',limit); main.rate_limit(user,'test',limit)
    with pytest.raises(HTTPException) as exc: main.rate_limit(user,'test',limit)
    assert exc.value.status_code==429 and exc.value.headers['Retry-After']=='60'
    for i in range(7): main.rate_limit({'sub':f'guest:{i}','public_read':True},'test',limit)
    with pytest.raises(HTTPException): main.rate_limit({'sub':'guest:new','public_read':True},'test',limit)
