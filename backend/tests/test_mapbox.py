from uuid import uuid4
import httpx
import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient
from app import mapbox
from app.main import app
from app.auth import identity
from app.models import MapboxCategorySearch, MapboxSuggest, MapboxRetrieve

BODY={'proximity': {'coordinates': [-87.625,41.885]},'bbox': [-87.63,41.88,-87.62,41.89]}

def test_category_request_and_provider_metadata(monkeypatch):
    monkeypatch.setenv('MAPBOX_ACCESS_TOKEN','test-token')
    payload={'type':'FeatureCollection','attribution':'Mapbox test attribution','features':[
        {'type':'Feature','properties':{'name':'Cafe','metadata':{'website':'https://example.com'},'operational_status':'active'}}]}
    def get(url,params,timeout):
        assert url.endswith('/category/coffee')
        assert params['bbox']=='-87.63,41.88,-87.62,41.89'
        assert params['proximity']=='-87.625,41.885'
        assert params['access_token']=='test-token'
        assert 'session_token' not in params
        return httpx.Response(200,json=payload,request=httpx.Request('GET',url))
    monkeypatch.setattr(mapbox.httpx,'get',get)
    result=mapbox.category_search(MapboxCategorySearch(**BODY))
    assert result['data']==payload
    assert result['storage']=='temporary'
    assert result['arrival_hours_status']=='unknown'

def test_session_continuity_and_visit_metadata(monkeypatch):
    monkeypatch.setenv('MAPBOX_ACCESS_TOKEN','test-token')
    session=uuid4(); seen=[]
    def get(url,params,timeout):
        seen.append(params)
        result={'suggestions':[]} if url.endswith('/suggest') else {'type':'FeatureCollection','features':[]}
        return httpx.Response(200,json=result,request=httpx.Request('GET',url))
    monkeypatch.setattr(mapbox.httpx,'get',get)
    mapbox.suggest(MapboxSuggest(query='Cafe',proximity=BODY['proximity'],session_token=session))
    mapbox.retrieve(MapboxRetrieve(mapbox_id='dXJu:example',session_token=session))
    assert all(p['session_token']==str(session) for p in seen)
    assert seen[1]['attribute_sets']=='visit'

@pytest.mark.parametrize('status,expected',[(401,502),(429,503),(500,502)])
def test_provider_failure_does_not_leak_token(monkeypatch,status,expected):
    monkeypatch.setenv('MAPBOX_ACCESS_TOKEN','sensitive-token')
    def get(url,params,timeout):
        return httpx.Response(status,request=httpx.Request('GET',url,params=params))
    monkeypatch.setattr(mapbox.httpx,'get',get)
    with pytest.raises(HTTPException) as exc:
        mapbox.category_search(MapboxCategorySearch(**BODY))
    assert exc.value.status_code==expected
    assert 'sensitive-token' not in str(exc.value)

def test_configuration_missing(monkeypatch):
    monkeypatch.delenv('MAPBOX_ACCESS_TOKEN',raising=False)
    with pytest.raises(HTTPException) as exc: mapbox.category_search(MapboxCategorySearch(**BODY))
    assert exc.value.status_code==503

def test_endpoint_is_public_and_disables_storage(monkeypatch):
    import app.main as main
    client=TestClient(app)
    url='/api/v1/commercial/mapbox/category'
    monkeypatch.setattr(main,'rate_limit',lambda *a: None)
    monkeypatch.setattr(mapbox,'category_search',lambda body: {'provider':'mapbox','storage':'temporary',
        'arrival_hours_status':'unknown','data':{'type':'FeatureCollection','features':[]}})
    try:
        result=client.post(url,json=BODY)
        assert result.status_code==200
        assert result.headers['cache-control']=='private, no-store'
        assert client.post(url,json={**BODY,'bbox':[170,0,-170,1]}).status_code==422
    finally: app.dependency_overrides.clear()
