from contextlib import asynccontextmanager
from time import monotonic
import hashlib
import hmac
import secrets
import json
import os
from typing import Annotated, Union, Optional
from uuid import UUID
from fastapi import FastAPI, Body, Depends, HTTPException, Response, Request
from fastapi.encoders import jsonable_encoder
from psycopg import errors
from psycopg.types.json import Jsonb
from .auth import identity,reviewer,admin
from .db import transaction
from .models import (ExistingReport,Suggestion,ReportReceipt,IngestRequest,DiscoveryRequest,CurateRequest,CuratedRoute,
                     Review,POIReview,QueueEdit,QueueReceipt,MapboxCategorySearch,MapboxSuggest,MapboxRetrieve,MapboxResponse,DiscoveryResponse)
from .providers import baseline_osm
from .discovery import search_area, start_worker, stop_worker
from . import mapbox
from .hours import enrich_poi
from datetime import datetime
from .curation import curate

@asynccontextmanager
async def lifespan(app):
    start_worker()
    try: yield
    finally: stop_worker()

app=FastAPI(lifespan=lifespan,title='PausePath Micro-Amenity API',version='1.0.0',
    description='PostGIS-backed walking/running break curation and community verification. No medical readiness or exertion inference.')

from .community_features import router as community_router
app.include_router(community_router)

_booted_at = monotonic()

@app.middleware('http')
async def request_timing(request, call_next):
    started = monotonic()
    response = await call_next(request)
    response.headers['Server-Timing'] = f'api;dur={(monotonic()-started)*1000:.1f}'
    response.headers['X-Service-Uptime-Seconds'] = str(int(monotonic()-_booted_at))
    return response

# Public reads never grant a Supabase identity or database privileges. Raw IPs
# are not persisted; client-controlled forwarding headers are not read here.
_public_salt = secrets.token_bytes(32)

def public_reader(request: Request):
    peer = request.client.host if request.client else 'unknown'
    digest = hmac.new(_public_salt, peer.encode(), hashlib.sha256).hexdigest()
    return {'sub': 'guest:' + digest, 'public_read': True}

def rate_limit(user, action, limit=30):
    if user.get('public_read'):
        # Shared global ceiling also bounds costs across replicas/restarts and
        # clients behind proxies. Per-peer limits may be shared behind a NAT.
        rate_limit({'sub':'public-read-budget'}, action, limit * 5)
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

@app.post('/api/v1/communities',tags=['community'])
def create_community(body: dict=Body(...),user=Depends(identity)):
    rate_limit(user,'community',8)
    raw_name=body.get('name')
    name=raw_name.strip() if isinstance(raw_name,str) else ''
    if not 2 <= len(name) <= 60: raise HTTPException(422,'Community name must be 2–60 characters')
    raw_display=body.get('display_name')
    display=raw_display.strip() if isinstance(raw_display,str) else ''
    if not 1 <= len(display) <= 32: raise HTTPException(422,'Choose a community username from 1 to 32 characters')
    key=body.get('request_id')
    try: key=UUID(str(key)) if key else None
    except ValueError: raise HTTPException(422,'Invalid request ID')
    code=secrets.token_urlsafe(6).replace('-','').replace('_','').upper()[:8]
    with transaction() as conn:
        # Serialize retries by identity and key before looking up the earlier result.
        if key:
            conn.execute('SELECT pg_advisory_xact_lock(hashtextextended(%s,0))',(user['sub']+str(key),))
            existing=conn.execute('SELECT id,name,invite_code,created_at FROM walking_communities WHERE created_by=%s AND request_id=%s',(user['sub'],key)).fetchone()
            if existing:
                count=conn.execute('SELECT count(*) AS n FROM walking_community_members WHERE community_id=%s',(existing['id'],)).fetchone()['n']
                return {**existing,'member_count':count,'my_display_name':display,'is_owner':True}
        row=conn.execute('INSERT INTO walking_communities(name,invite_code,created_by,request_id) VALUES (%s,%s,%s,%s) RETURNING id,name,invite_code,created_at',(name,code,user['sub'],key)).fetchone()
        conn.execute('INSERT INTO walking_community_members(community_id,user_id,display_name) VALUES (%s,%s,%s)',(row['id'],user['sub'],display))
    return {**row,'member_count':1,'my_display_name':display,'is_owner':True}

@app.post('/api/v1/communities/join',tags=['community'])
def join_community(body: dict=Body(...),user=Depends(identity)):
    rate_limit(user,'community',12)
    raw_code=body.get('invite_code')
    code=raw_code.strip().upper() if isinstance(raw_code,str) else ''
    if not 4 <= len(code) <= 12: raise HTTPException(422,'Enter a valid invite code')
    raw_display=body.get('display_name')
    display=raw_display.strip() if isinstance(raw_display,str) else ''
    if not 1 <= len(display) <= 32: raise HTTPException(422,'Choose a community username from 1 to 32 characters')
    with transaction() as conn:
        row=conn.execute('SELECT id,name,invite_code,created_at FROM walking_communities WHERE invite_code=%s',(code,)).fetchone()
        if not row: raise HTTPException(404,'That invite code was not found')
        conn.execute('INSERT INTO walking_community_members(community_id,user_id,display_name) VALUES (%s,%s,%s) ON CONFLICT (community_id,user_id) DO UPDATE SET display_name=excluded.display_name',(row['id'],user['sub'],display))
        member=conn.execute('SELECT display_name FROM walking_community_members WHERE community_id=%s AND user_id=%s',(row['id'],user['sub'])).fetchone()
        count=conn.execute('SELECT count(*) AS n FROM walking_community_members WHERE community_id=%s',(row['id'],)).fetchone()['n']
    return {**row,'member_count':count,'my_display_name':member['display_name']}

@app.post('/api/v1/communities/username',tags=['community'])
def update_community_username(body: dict=Body(...),user=Depends(identity)):
    raw=body.get('display_name')
    display=raw.strip() if isinstance(raw,str) else ''
    if not 1 <= len(display) <= 32: raise HTTPException(422,'Choose a community username from 1 to 32 characters')
    with transaction() as conn:
        conn.execute('UPDATE walking_community_members SET display_name=%s WHERE user_id=%s',(display,user['sub']))
    return {'saved':True,'display_name':display}

@app.get('/api/v1/communities',tags=['community'])
def list_communities(user=Depends(identity)):
    with transaction() as conn:
        rows=conn.execute('''SELECT c.id,c.name,c.invite_code,c.created_at,m.display_name AS my_display_name, (c.created_by=m.user_id) AS is_owner,
            (SELECT count(*) FROM walking_community_members m2 WHERE m2.community_id=c.id) AS member_count,
            (SELECT coalesce(jsonb_agg(m3.display_name ORDER BY lower(m3.display_name)),'[]'::jsonb)
                FROM walking_community_members m3 WHERE m3.community_id=c.id) AS members
            FROM walking_community_members m JOIN walking_communities c ON c.id=m.community_id
            WHERE m.user_id=%s ORDER BY c.created_at DESC''',(user['sub'],)).fetchall()
    return {'communities':rows}

@app.post('/api/v1/communities/{community_id}/challenges',tags=['community'])
def create_challenge(community_id: UUID,body: dict=Body(...),user=Depends(identity)):
    rate_limit(user,'challenge',12)
    raw_name=body.get('name'); name=raw_name.strip() if isinstance(raw_name,str) else ''
    metric=body.get('metric'); target=body.get('target')
    if not 2 <= len(name) <= 80: raise HTTPException(422,'Challenge name must be 2–80 characters')
    if metric not in ('distance_km','walks','minutes','new_routes'): raise HTTPException(422,'Choose a supported challenge type')
    if not isinstance(target,(int,float)) or isinstance(target,bool) or not 1 <= target <= 10000: raise HTTPException(422,'Choose a goal from 1 to 10,000')
    shared=body.get('shared_goal',False)
    if type(shared) is not bool: raise HTTPException(422,'Invalid goal mode')
    with transaction() as conn:
        if not conn.execute('SELECT 1 FROM walking_community_members WHERE community_id=%s AND user_id=%s',(community_id,user['sub'])).fetchone(): raise HTTPException(403,'Join this community before creating a challenge')
        row=conn.execute('INSERT INTO walking_challenges(community_id,name,metric,target,created_by,shared_goal) VALUES (%s,%s,%s,%s,%s,%s) RETURNING id,community_id,name,metric,target,created_at',(community_id,name,metric,target,user['sub'],shared)).fetchone()
        conn.execute('INSERT INTO walking_challenge_progress(challenge_id,user_id,amount) VALUES (%s,%s,0)',(row['id'],user['sub']))
    return row

@app.get('/api/v1/communities/{community_id}/challenges',tags=['community'])
def list_challenges(community_id: UUID,user=Depends(identity)):
    with transaction() as conn:
        if not conn.execute('SELECT 1 FROM walking_community_members WHERE community_id=%s AND user_id=%s',(community_id,user['sub'])).fetchone(): raise HTTPException(403,'Join this community to view its challenges')
        rows=conn.execute('''SELECT c.id,c.community_id,c.name,c.metric,c.target,c.created_at,c.shared_goal,
            (SELECT coalesce(sum(amount),0) FROM walking_challenge_progress WHERE challenge_id=c.id) AS group_progress,
            (c.created_by=%s OR EXISTS(SELECT 1 FROM walking_communities g WHERE g.id=c.community_id AND g.created_by=%s)) AS can_delete,
            coalesce((SELECT p.amount FROM walking_challenge_progress p WHERE p.challenge_id=c.id AND p.user_id=%s),0) AS my_progress,
            coalesce((SELECT jsonb_agg(jsonb_build_object('name',ranked.display_name,'amount',ranked.amount) ORDER BY ranked.amount DESC)
                FROM (SELECT m.display_name,coalesce(p.amount,0) AS amount FROM walking_community_members m
                    LEFT JOIN walking_challenge_progress p ON p.user_id=m.user_id AND p.challenge_id=c.id
                    WHERE m.community_id=c.community_id ORDER BY amount DESC LIMIT 50) ranked),'[]'::jsonb) AS leaderboard
            FROM walking_challenges c WHERE c.community_id=%s ORDER BY c.created_at DESC''',(user['sub'],user['sub'],user['sub'],community_id)).fetchall()
    return {'challenges':rows}

@app.post('/api/v1/challenges/{challenge_id}/progress',tags=['community'])
def update_challenge_progress(challenge_id: UUID,body: dict=Body(...),user=Depends(identity)):
    amount=body.get('amount')
    if not isinstance(amount,(int,float)) or isinstance(amount,bool) or not 0 <= amount <= 100000: raise HTTPException(422,'Progress must be between 0 and 100,000')
    with transaction() as conn:
        joined=conn.execute('''SELECT 1 FROM walking_challenges c JOIN walking_community_members m ON m.community_id=c.community_id
            WHERE c.id=%s AND m.user_id=%s''',(challenge_id,user['sub'])).fetchone()
        if not joined: raise HTTPException(403,'Join the challenge community before updating progress')
        conn.execute('''INSERT INTO walking_challenge_progress(challenge_id,user_id,amount) VALUES (%s,%s,%s)
            ON CONFLICT (challenge_id,user_id) DO UPDATE SET amount=excluded.amount,updated_at=now()''',(challenge_id,user['sub'],amount))
    return {'saved':True,'amount':amount}

@app.post('/api/v1/challenges/{challenge_id}/progress/delete',tags=['community'])
def delete_challenge_progress(challenge_id: UUID,user=Depends(identity)):
    with transaction() as conn:
        conn.execute('''DELETE FROM walking_challenge_progress p USING walking_challenges c,walking_community_members m
            WHERE p.challenge_id=c.id AND m.community_id=c.community_id AND m.user_id=%s
            AND c.id=%s AND p.user_id=%s''',(user['sub'],challenge_id,user['sub']))
    return {'deleted':True}

@app.post('/api/v1/routes/curate',response_model=CuratedRoute,tags=['routes'])
def curate_route(body: CurateRequest,user=Depends(public_reader)):
    rate_limit(user,'curate',6)
    if not (os.environ.get('PEDESTRIAN_ROUTER_URL') or os.environ.get('MAPBOX_ACCESS_TOKEN')): raise HTTPException(503,'Pedestrian routing provider must be configured')
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

@app.post('/api/v1/pois/search',response_model=DiscoveryResponse,tags=['pois'])
def discover_pois(body: DiscoveryRequest,response: Response,user=Depends(public_reader)):
    rate_limit(user,'discovery',120)
    response.headers['Cache-Control']='private, no-store'
    return search_area(body)

@app.get('/api/v1/pois/{poi_id}',tags=['pois'])
def get_poi(poi_id: UUID,arrival_at: Optional[datetime] = None,user=Depends(public_reader)):
    if arrival_at is not None and arrival_at.tzinfo is None: raise HTTPException(422,"arrival_at must include a timezone")
    rate_limit(user,'poi',60)
    with transaction() as conn:
        row=conn.execute('''SELECT id,source,external_id,name,category,ST_AsGeoJSON(geom)::jsonb AS location,
                           is_active,confidence_score,operating_hours,attributes,closed_until,source_updated_at,
                           (SELECT max(r.created_at) FROM poi_reports r WHERE r.poi_id=pois.id AND r.report_type='confirm_exists') AS last_verified_at,
                           (SELECT r.created_at FROM poi_reports r WHERE r.poi_id=pois.id ORDER BY r.created_at DESC,r.id DESC LIMIT 1) AS last_reported_at,
                           (SELECT r.report_type FROM poi_reports r WHERE r.poi_id=pois.id ORDER BY r.created_at DESC,r.id DESC LIMIT 1) AS last_report_type
                           FROM pois WHERE id=%s''',(poi_id,)).fetchone()
    if not row: raise HTTPException(404,'POI not found')
    return enrich_poi(row, arrival_at)

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
def mapbox_category(body: MapboxCategorySearch,response: Response,user=Depends(public_reader)):
    commercial_response(response,user)
    return mapbox.category_search(body)

@app.post('/api/v1/commercial/mapbox/suggest',response_model=MapboxResponse,tags=['commercial'])
def mapbox_suggest(body: MapboxSuggest,response: Response,user=Depends(public_reader)):
    commercial_response(response,user)
    return mapbox.suggest(body)

@app.post('/api/v1/commercial/mapbox/retrieve',response_model=MapboxResponse,tags=['commercial'])
def mapbox_retrieve(body: MapboxRetrieve,response: Response,user=Depends(public_reader)):
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
