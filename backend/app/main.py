import hashlib
import json
import os
from typing import Annotated, Union
from uuid import UUID
from fastapi import FastAPI, Body, Depends, HTTPException, Response
from fastapi.encoders import jsonable_encoder
from psycopg import errors
from psycopg.types.json import Jsonb
from .auth import identity,reviewer,admin
from .db import transaction
from .models import (ExistingReport,Suggestion,ReportReceipt,IngestRequest,CurateRequest,CuratedRoute,
                     Review,POIReview,QueueEdit,QueueReceipt,MapboxCategorySearch,MapboxSuggest,MapboxRetrieve,MapboxResponse)
from .providers import baseline_osm
from . import mapbox
from .curation import curate

app=FastAPI(title='PausePath Micro-Amenity API',version='1.0.0',
    description='PostGIS-backed walking/running break curation and community verification. No medical readiness or exertion inference.')

def rate_limit(user, action, limit=30):
    # Shared database counters work across API replicas. Prune old buckets in maintenance.
    with transaction() as conn:
        row=conn.execute('''INSERT INTO api_rate_buckets(user_id,action,window_start)
            VALUES (%s,%s,date_trunc('minute',now())) ON CONFLICT(user_id,action,window_start)
            DO UPDATE SET count=api_rate_buckets.count+1 RETURNING count''',(user['sub'],action)).fetchone()
    if row['count']>limit: raise HTTPException(429,'Rate limit exceeded',headers={'Retry-After':'60'})

def audit(conn,user,action,subject,evidence):
    conn.execute('INSERT INTO moderation_audit(actor_id,action,subject_id,evidence) VALUES (%s,%s,%s,%s)',
                 (user['sub'],action,subject,evidence))

@app.get('/health', tags=['operations'])
def health(): return {'status':'ok'}

@app.get('/ready', tags=['operations'])
def ready():
    with transaction() as conn: conn.execute('SELECT id FROM pois LIMIT 1')
    return {'status':'ready'}

@app.post('/api/v1/routes/curate',response_model=CuratedRoute,tags=['routes'])
def curate_route(body: CurateRequest,user=Depends(identity)):
    rate_limit(user,'curate',6)
    if not os.environ.get('PEDESTRIAN_ROUTER_URL'): raise HTTPException(503,'Pedestrian routing provider must be configured')
    return curate(body)

@app.post('/api/v1/reports',response_model=ReportReceipt,status_code=201,tags=['community'])
def report(body: Annotated[Union[ExistingReport,Suggestion], Body(discriminator='kind')],user=Depends(identity)):
    rate_limit(user,'report',10)
    digest=hashlib.sha256(body.model_dump_json().encode()).hexdigest()
    try:
        with transaction() as conn:
            conn.execute('SELECT pg_advisory_xact_lock(hashtextextended(%s,0))',(user['sub'],))
            previous=conn.execute('SELECT * FROM api_request_receipts WHERE user_id=%s AND request_id=%s',
                                  (user['sub'],body.request_id)).fetchone()
            if previous:
                if previous['payload_hash']!=digest: raise HTTPException(409,'request_id was used for a different payload')
                return previous['response']
            count=conn.execute("SELECT count(*) AS n FROM api_request_receipts WHERE user_id=%s AND created_at>now()-interval '24 hours'",(user['sub'],)).fetchone()['n']
            if count>=60: raise HTTPException(429,'Daily reporting limit reached')
            if isinstance(body,ExistingReport):
                row=conn.execute('''INSERT INTO poi_reports(poi_id,user_id,report_type,request_id,payload_hash)
                    VALUES (%s,%s,%s,%s,%s) RETURNING id''',
                    (body.poi_id,user['sub'],body.report_type,body.request_id,digest)).fetchone()
                poi=conn.execute('SELECT confidence_score,is_active FROM pois WHERE id=%s',(body.poi_id,)).fetchone()
                result={'id':row['id'],'kind':'status','status':'recorded','poi_id':body.poi_id,**poi}
            else:
                lon,lat=body.location.coordinates
                row=conn.execute('''INSERT INTO poi_suggestions(user_id,request_id,payload_hash,name,category,geom,attributes)
                    VALUES (%s,%s,%s,%s,%s,ST_SetSRID(ST_MakePoint(%s,%s),4326),%s) RETURNING id''',
                    (user['sub'],body.request_id,digest,body.name,body.category,lon,lat,Jsonb(body.attributes.model_dump(exclude_none=True)))).fetchone()
                result={'id':row['id'],'kind':'suggestion','status':'pending_review'}
            encoded=jsonable_encoder(result)
            conn.execute('INSERT INTO api_request_receipts(user_id,request_id,payload_hash,response) VALUES (%s,%s,%s,%s)',
                         (user['sub'],body.request_id,digest,Jsonb(encoded)))
            return encoded
    except errors.ForeignKeyViolation: raise HTTPException(404,'POI not found')
    except errors.UniqueViolation: raise HTTPException(409,'A report for this POI was already submitted in the past 24 hours')

@app.post('/api/v1/admin/ingest/osm',tags=['ingestion'])
def ingest(body: IngestRequest,user=Depends(admin)):
    rate_limit(user,'ingest',2)
    with transaction() as conn: count=baseline_osm(conn,body)
    return {'upserted':count,'attribution':'© OpenStreetMap contributors, ODbL 1.0'}

@app.get('/api/v1/pois/{poi_id}',tags=['pois'])
def get_poi(poi_id: UUID,user=Depends(identity)):
    rate_limit(user,'poi',60)
    with transaction() as conn:
        row=conn.execute('''SELECT id,source,external_id,name,category,ST_AsGeoJSON(geom)::jsonb AS location,
                           is_active,confidence_score,operating_hours,attributes,closed_until,source_updated_at
                           FROM pois WHERE id=%s''',(poi_id,)).fetchone()
    if not row: raise HTTPException(404,'POI not found')
    return row

@app.post('/api/v1/suggestions/{suggestion_id}/review',tags=['moderation'])
def review_suggestion(suggestion_id: UUID,body: Review,user=Depends(reviewer)):
    with transaction() as conn:
        row=conn.execute('SELECT * FROM poi_suggestions WHERE id=%s FOR UPDATE',(suggestion_id,)).fetchone()
        if not row: raise HTTPException(404,'Suggestion not found')
        if row['status']!='pending': raise HTTPException(409,'Suggestion already reviewed')
        if row['user_id']==user['sub']: raise HTTPException(403,'A different reviewer must verify this suggestion')
        poi_id=None
        if body.decision=='approve':
            poi_id=conn.execute('''INSERT INTO pois(source,external_id,name,category,geom,attributes)
                SELECT 'community',id::text,name,category,geom,attributes FROM poi_suggestions WHERE id=%s RETURNING id''',(suggestion_id,)).fetchone()['id']
        status='approved' if poi_id else 'rejected'
        conn.execute('UPDATE poi_suggestions SET status=%s,poi_id=%s WHERE id=%s',(status,poi_id,suggestion_id))
        audit(conn,user,'suggestion_'+status,suggestion_id,body.evidence)
        return {'id':suggestion_id,'status':status,'poi_id':poi_id}

@app.patch('/api/v1/pois/{poi_id}/review',tags=['moderation'])
def review_poi(poi_id: UUID,body: POIReview,user=Depends(reviewer)):
    with transaction() as conn:
        row=conn.execute('SELECT id FROM pois WHERE id=%s FOR UPDATE',(poi_id,)).fetchone()
        if not row: raise HTTPException(404,'POI not found')
        conn.execute('UPDATE pois SET is_active=%s,updated_at=now() WHERE id=%s',(body.is_active,poi_id))
        if body.operating_hours is not None:
            hours={**body.operating_hours,'reviewed':True}
            conn.execute('UPDATE pois SET operating_hours=%s WHERE id=%s',(Jsonb(hours),poi_id))
        if body.attributes is not None:
            attrs=body.attributes.model_dump(exclude_none=True)
            conn.execute("UPDATE pois SET attributes=attributes || %s::jsonb || jsonb_build_object('reviewed_attributes',%s::jsonb) WHERE id=%s",(Jsonb(attrs),Jsonb(attrs),poi_id))
        audit(conn,user,'poi_review',poi_id,body.evidence)
    return {'id':poi_id,'is_active':body.is_active}

def commercial_response(response, user):
    response.headers['Cache-Control']='private, no-store'
    response.headers['Vary']='Authorization'
    rate_limit(user,'commercial',20)

@app.post('/api/v1/commercial/mapbox/category',response_model=MapboxResponse,tags=['commercial'])
def mapbox_category(body: MapboxCategorySearch,response: Response,user=Depends(identity)):
    commercial_response(response,user)
    return mapbox.category_search(body)

@app.post('/api/v1/commercial/mapbox/suggest',response_model=MapboxResponse,tags=['commercial'])
def mapbox_suggest(body: MapboxSuggest,response: Response,user=Depends(identity)):
    commercial_response(response,user)
    return mapbox.suggest(body)

@app.post('/api/v1/commercial/mapbox/retrieve',response_model=MapboxResponse,tags=['commercial'])
def mapbox_retrieve(body: MapboxRetrieve,response: Response,user=Depends(identity)):
    commercial_response(response,user)
    return mapbox.retrieve(body)

@app.post('/api/v1/osm/queue',status_code=201,tags=['osm'])
def queue_osm(body: QueueEdit,user=Depends(reviewer)):
    try:
        with transaction() as conn:
            row=conn.execute('SELECT *,ST_AsGeoJSON(geom)::jsonb AS location FROM pois WHERE id=%s FOR UPDATE',(body.poi_id,)).fetchone()
            if not row: raise HTTPException(404,'POI not found')
            if body.action=='add' and (row['source']!='community' or not row['is_active']): raise HTTPException(409,'Only reviewed, active community POIs can be added')
            if body.action=='remove' and (row['source']!='osm' or not row['external_id'].startswith('node/') or row['is_active']):
                raise HTTPException(409,'Removal queue requires an inactive OSM node; ways/relations require manual editing')
            if body.action=='add' and conn.execute("SELECT id FROM osm_edit_queue WHERE poi_id=%s AND action='add' AND status='submitted'",(body.poi_id,)).fetchone():
                raise HTTPException(409,'This POI was already submitted; reconcile its OSM identity instead of creating a duplicate')
            amenity={'toilet':'toilets'}.get(row['category'],row['category'])
            payload={'location':row['location'],'external_id':row['external_id'],'tags':{'amenity':amenity}}
            if row['name']: payload['tags']['name']=row['name']
            queue=conn.execute('''INSERT INTO osm_edit_queue(poi_id,action,payload,verified_by,evidence)
                VALUES (%s,%s,%s,%s,%s) RETURNING id,status''',(body.poi_id,body.action,Jsonb(payload),user['sub'],body.evidence)).fetchone()
            audit(conn,user,'osm_queue_'+body.action,body.poi_id,body.evidence)
            return queue
    except errors.UniqueViolation: raise HTTPException(409,'A pending edit already exists for this POI')

@app.get('/api/v1/osm/queue',tags=['osm'])
def list_osm_queue(user=Depends(reviewer)):
    with transaction() as conn:
        return conn.execute("SELECT id,poi_id,action,payload,evidence,status,changeset_id FROM osm_edit_queue WHERE status!='submitted' ORDER BY created_at LIMIT 100").fetchall()

@app.post('/api/v1/osm/queue/{edit_id}/claim',tags=['osm'])
def claim_osm(edit_id: UUID,user=Depends(reviewer)):
    with transaction() as conn:
        row=conn.execute("UPDATE osm_edit_queue SET status='claimed',claimed_by=%s,updated_at=now() WHERE id=%s AND status='queued' RETURNING *",(user['sub'],edit_id)).fetchone()
        if not row: raise HTTPException(409,'Edit unavailable or already claimed; reconcile uncertain uploads before retrying')
        return row

@app.put('/api/v1/osm/queue/{edit_id}/changeset/{changeset_id}',tags=['osm'])
def record_changeset(edit_id: UUID,changeset_id: int,user=Depends(reviewer)):
    if changeset_id<=0: raise HTTPException(422,'Invalid changeset ID')
    with transaction() as conn:
        row=conn.execute("UPDATE osm_edit_queue SET changeset_id=%s,updated_at=now() WHERE id=%s AND claimed_by=%s AND status='claimed' AND changeset_id IS NULL RETURNING id",(changeset_id,edit_id,user['sub'])).fetchone()
        if not row: raise HTTPException(409,'Claim/changeset conflict')
    return {'id':edit_id,'changeset_id':changeset_id}

@app.post('/api/v1/osm/queue/{edit_id}/receipt',tags=['osm'])
def osm_receipt(edit_id: UUID,body: QueueReceipt,user=Depends(reviewer)):
    with transaction() as conn:
        row=conn.execute("UPDATE osm_edit_queue SET status=%s,updated_at=now() WHERE id=%s AND claimed_by=%s AND changeset_id=%s AND status='claimed' RETURNING id,status",(body.status,edit_id,user['sub'],body.changeset_id)).fetchone()
        if not row: raise HTTPException(409,'Receipt does not match the claimed changeset')
        return row
