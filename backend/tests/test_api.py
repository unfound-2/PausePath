from fastapi.testclient import TestClient
from app.main import app

client=TestClient(app)

def test_health_and_schema():
    assert client.get('/health').json()=={'status':'ok'}
    spec=client.get('/openapi.json').json()
    assert '/api/v1/routes/curate' in spec['paths']
    assert spec['paths']['/api/v1/reports']['post']['security']
    assert spec['components']['schemas']['CuratedRoute']['properties']['type']['const']=='Feature'

def test_unauthenticated_reports_cannot_write():
    response=client.post('/api/v1/reports',json={'kind':'status','request_id':'00000000-0000-0000-0000-000000000001',
        'poi_id':'00000000-0000-0000-0000-000000000002','report_type':'removed'})
    assert response.status_code==401

def test_unauthenticated_ingestion_blocked():
    assert client.post('/api/v1/admin/ingest/osm',json={'south':41.88,'west':-87.63,'north':41.89,'east':-87.62}).status_code==401
