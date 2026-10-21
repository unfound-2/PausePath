import json
import time
from datetime import timedelta
from pathlib import Path
import httpx
from fastapi import HTTPException
from .db import transaction
from .geometry import densify,at_distance
from .hours import open_during, normalize_osm_hours
from .providers import pedestrian_connector

QUERY = Path(__file__).with_name('candidates.sql').read_text()

def curate(request, connector=pedestrian_connector):
    try: path,total = densify(request.geometry.coordinates)
    except ValueError as exc: raise HTTPException(422,str(exc))
    interval=request.preferences.target_break_interval_meters
    targets=[interval*i for i in range(1,int(total//interval)+1) if interval*i < total-1]
    if len(targets)>50: raise HTTPException(422,'Use at most 50 break targets per request')
    speed=request.speed_meters_per_second or (1.2 if request.movement_type=='walk' else 2.5)
    categories=request.preferences.prioritized_categories
    weights={category:len(categories)-index for index,category in enumerate(categories)}
    geometry=json.dumps({'type':'LineString','coordinates':path})
    selected=[]; missing=[]; used=set(); extra=0.0; elapsed_breaks=0; last_marker=-1
    deadline=time.monotonic()+45; connector_checks=0
    warnings=['Base geometry is unchanged. Follow the outbound and return connector geometries at each break.',
              'Amenity data and pedestrian routing may be incomplete. This is not medical or exertion guidance.']
    for target in targets:
        if time.monotonic() >= deadline or connector_checks>=60:
            missing.append(target)
            if 'Search budget reached; some targets were not fully evaluated.' not in warnings:
                warnings.append('Search budget reached; some targets were not fully evaluated.')
            continue
        lon,lat=at_distance(path,target)
        projection=f'+proj=aeqd +lat_0={lat} +lon_0={lon} +datum=WGS84 +units=m +no_defs'
        with transaction() as conn:
            rows=conn.execute(QUERY,{'route':geometry,'lon':lon,'lat':lat,'target':target,
                'projection':projection,'categories':categories,'weights':json.dumps(weights),
                'wheelchair':request.preferences.require_wheelchair_accessible}).fetchall()
        chosen=None
        for row in rows:
            if time.monotonic() >= deadline or connector_checks>=60: break
            if str(row['id']) in used or row['marker_m']<=last_marker: continue
            # Area centroids are not reliable public entrances.
            if row['attributes'].get('coordinate_is_area_center'): continue
            connector_checks+=1
            try:
                access=connector(row['attachment']['coordinates'],row['location']['coordinates'],request.preferences.max_connector_meters)
            except (httpx.HTTPError,ValueError,KeyError,TypeError):
                if 'Some pedestrian access checks failed.' not in warnings: warnings.append('Some pedestrian access checks failed.')
                continue
            if access is None: continue
            arrival=request.departure_at+timedelta(seconds=(row['marker_m']+extra+access['outbound_meters'])/speed+elapsed_breaks)
            if row['closed_until'] and row['closed_until']>arrival: continue
            availability=open_during(normalize_osm_hours(row['operating_hours'],*row['location']['coordinates']),arrival,request.preferences.break_duration_seconds)
            if availability is False: continue
            known_open=availability is True
            if not known_open and not request.preferences.allow_unknown_hours: continue
            chosen={'target_distance_meters':target,'distance_marker_meters':row['marker_m'],
                'distance_from_target_meters':row['target_distance'],'arrival_at':arrival,
                'score':row['score'],'hours_status':'open' if known_open else 'unknown',
                'poi':{key:row[key] for key in ('id','name','category','confidence_score','location','attributes','source','external_id')},
                'connector':access}
            selected.append(chosen); used.add(str(row['id'])); last_marker=row['marker_m']
            extra+=access['outbound_meters']+access['return_meters']
            elapsed_breaks+=request.preferences.break_duration_seconds
            break
        if chosen is None: missing.append(target)
    if missing: warnings.append('Unfilled targets remain explicit; requested intervals are not guaranteed.')
    return {'type':'Feature','geometry':request.geometry.model_dump(), 'properties':{
        'base_distance_meters':total,'total_distance_with_detours_meters':total+extra,
        'movement_type':request.movement_type,'speed_meters_per_second':speed,'break_points':selected,
        'unfilled_targets_meters':missing,'all_targets_filled':not missing,'geometry_includes_detours':False,
        'attribution':'© OpenStreetMap contributors; community reports by PausePath users','warnings':warnings}}
