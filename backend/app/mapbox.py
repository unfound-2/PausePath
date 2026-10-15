"""Request-scoped Mapbox Search Box data; never persisted or exported to OSM."""
import os
from urllib.parse import quote
import httpx
from fastapi import HTTPException

BASE_URL = 'https://api.mapbox.com/search/searchbox/v1'

def search_box(path, params, expected):
    token = os.environ.get('MAPBOX_ACCESS_TOKEN')
    if not token:
        raise HTTPException(503, 'Mapbox Search is not configured')
    try:
        response = httpx.get(BASE_URL + path, params={**params, 'access_token': token}, timeout=8)
        if response.status_code == 429:
            raise HTTPException(503, 'Mapbox Search is temporarily rate limited', headers={'Retry-After': '60'})
        response.raise_for_status()
        payload = response.json()
        if not isinstance(payload, dict) or not isinstance(payload.get(expected), list):
            raise ValueError('Invalid provider response')
        if expected == 'features' and payload.get('type') != 'FeatureCollection':
            raise ValueError('Invalid provider geometry response')
        # Preserve attribution and optional metadata without inventing hours or
        # treating an operational_status of active as open at arrival time.
        return {'provider': 'mapbox', 'storage': 'temporary', 'data': payload,
                'arrival_hours_status': 'unknown'}
    except (httpx.HTTPError, ValueError):
        # Never include an exception URL: Mapbox credentials are query parameters.
        raise HTTPException(502, 'Mapbox Search unavailable') from None

def category_search(body):
    west, south, east, north = body.bbox
    params = {'proximity': f'{body.proximity.coordinates[0]},{body.proximity.coordinates[1]}',
              'bbox': f'{west},{south},{east},{north}', 'limit': body.limit, 'language': body.language}
    return search_box('/category/' + body.category, params, 'features')

def suggest(body):
    return search_box('/suggest', {'q': body.query, 'session_token': str(body.session_token),
        'proximity': ','.join(map(str, body.proximity.coordinates)), 'types': 'poi',
        'limit': body.limit, 'language': body.language}, 'suggestions')

def retrieve(body):
    return search_box('/retrieve/' + quote(body.mapbox_id, safe=''),
        {'session_token': str(body.session_token), 'language': body.language,
         'attribute_sets': 'visit'}, 'features')
