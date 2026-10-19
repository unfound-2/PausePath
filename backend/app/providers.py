import os
import httpx
from fastapi import HTTPException
from psycopg.types.json import Jsonb
from .geometry import distance

AMENITIES = {'bench':'bench','toilets':'toilet','drinking_water':'drinking_water','cafe':'cafe'}

def fetch_osm(bbox):
    bounds = ','.join(str(getattr(bbox,k)) for k in ('south','west','north','east'))
    query = '[out:json][timeout:25];nwr["amenity"~"^(bench|toilets|drinking_water|cafe)$"]('+bounds+');out body center;'
    # Independent public mirrors keep a single upstream outage from hiding node amenities.
    # An explicitly configured endpoint remains exclusive (for private deployments).
    configured = os.environ.get('OVERPASS_URL')
    endpoints = [configured] if configured and configured != "https://overpass-api.de/api/interpreter" else [
        'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
        'https://overpass.private.coffee/api/interpreter',
    ]
    payload = None
    for endpoint in endpoints:
        try:
            response = httpx.post(endpoint, data={'data': query}, timeout=30,
                                  headers={'User-Agent': 'PausePath/0.1'})
            response.raise_for_status()
            candidate = response.json()
            if not isinstance(candidate, dict) or candidate.get('remark'):
                continue  # Never persist partial responses as a complete area refresh.
            payload = candidate
            break
        except (httpx.HTTPError, ValueError):
            continue
    if payload is None:
        raise HTTPException(502, 'OSM baseline provider unavailable')
    elements = payload.get('elements',[])
    if len(elements) > 20000: raise HTTPException(413,'Too many POIs; use a smaller bounding box')
    return elements

def baseline_osm(conn, bbox):
    return store_osm(conn, fetch_osm(bbox))

def store_osm(conn, elements):
    rows = []
    for item in elements:
        tags = item.get('tags',{}); category = AMENITIES.get(tags.get('amenity'))
        coordinate = item if item.get('type') == 'node' else item.get('center',{})
        lon,lat = coordinate.get('lon'),coordinate.get('lat')
        if not category or lon is None or lat is None or not (-180 <= lon <=180 and -90 <=lat<=90): continue
        attributes = {'osm_tags':tags,'coordinate_is_area_center':item['type'] != 'node'}
        for key,tag in [('backrest','backrest'),('wheelchair_accessible','wheelchair'),('shaded','shaded')]:
            if tags.get(tag) in ('yes','no'): attributes[key] = tags[tag] == 'yes'
        attributes['access'] = {'yes':'public','public':'public','customers':'customers','private':'private','no':'private'}.get(tags.get('access'),'unknown')
        hours = {'raw':tags['opening_hours']} if tags.get('opening_hours') else None
        rows.append((str(item['type'])+'/'+str(item['id']),tags.get('name'),category,lon,lat,Jsonb(hours),Jsonb(attributes)))
    if not rows: return 0
    # Psycopg batches this through pipeline mode instead of one network round trip per POI.
    with conn.cursor() as cursor:
        cursor.executemany('''INSERT INTO pois(source,external_id,name,category,geom,operating_hours,attributes)
            VALUES ('osm',%s,%s,%s,ST_SetSRID(ST_MakePoint(%s,%s),4326),%s,%s)
            ON CONFLICT(source,external_id) DO UPDATE SET name=excluded.name,category=excluded.category,
              geom=excluded.geom,operating_hours=CASE WHEN pois.operating_hours ? 'reviewed' THEN pois.operating_hours ELSE excluded.operating_hours END,
              attributes=excluded.attributes || coalesce(pois.attributes->'reviewed_attributes','{}'::jsonb) ||
                 CASE WHEN pois.attributes ? 'reviewed_attributes' THEN jsonb_build_object('reviewed_attributes',pois.attributes->'reviewed_attributes') ELSE '{}'::jsonb END,
              source_updated_at=now(),updated_at=now()''',
            rows)
    return len(rows)

def pedestrian_connector(start, end, max_meters):
    base = os.environ.get('PEDESTRIAN_ROUTER_URL','').rstrip('/')
    token = os.environ.get('MAPBOX_ACCESS_TOKEN')
    if not base and not token: raise HTTPException(503,'Configure pedestrian routing to verify access')
    result = {}
    with httpx.Client(timeout=4) as client:
        for name,a,b in [('outbound',start,end),('return',end,start)]:
            path = f'{a[0]},{a[1]};{b[0]},{b[1]}'
            params = {'overview':'full','geometries':'geojson','steps':'false'}
            url = base+'/route/v1/foot/'+path if base else 'https://api.mapbox.com/directions/v5/mapbox/walking/'+path
            if not base: params['access_token'] = token
            response = client.get(url,params=params)
            response.raise_for_status(); data=response.json()
            if data.get('code') != 'Ok' or not data.get('routes'): return None
            route=data['routes'][0]; waypoints=data.get('waypoints',[])
            if len(waypoints)!=2 or any(distance(w['location'],point)>25 for w,point in zip(waypoints,[a,b])): return None
            if route['distance'] > max_meters or route['distance'] < 0: return None
            shape=route['geometry']
            if shape.get('type')!='LineString' or len(shape.get('coordinates',[]))<2: return None
            # Include short access offsets explicitly instead of silently teleporting
            # from the provided POI coordinate to a router's snapped endpoint.
            points=[a]+shape['coordinates']+[b]
            access=distance(a,shape['coordinates'][0])+distance(shape['coordinates'][-1],b)
            if route['distance']+access > max_meters: return None
            result[name]={'type':'LineString','coordinates':points}
            result[name+'_meters']=route['distance']+access
    return result
