"""Download complete OSM amenity snapshots for broad testing envelopes.

This is an explicit one-off administrative download, not a public API endpoint.
Outputs are resumable and ignored by Git when --output is under .build/.
Import through store_osm (which preserves community reviews) before marking
any discovery tiles ready. A successful snapshot is not real-world completeness.
"""
import argparse
import json
import time
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen

REGIONS = {
    'houston': (28.8, -96.6, 31.0, -94.2),
    'washington-dc': (38.1, -78.5, 40.0, -75.8),
}
PROVIDERS = (
    'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
    'https://overpass.private.coffee/api/interpreter',
    'https://overpass-api.de/api/interpreter',
)


def download(region, output, bounds=None):
    bounds = bounds or REGIONS[region]
    target = output / (region + '.json')
    if target.exists():
        saved = json.loads(target.read_text())
        if saved.get('complete') and saved.get('bounds') == list(bounds):
            print(f'{region}: reuse {len(saved["elements"])} downloaded elements', flush=True)
            return
    query = ('[out:json][timeout:25];nwr["amenity"~"^(bench|toilets|drinking_water|cafe)$"]('
             + ','.join(map(str, bounds)) + ');out body center;')
    for provider in PROVIDERS:
        try:
            request = Request(provider + '?' + urlencode({'data': query}),
                              headers={'User-Agent': 'PausePath testing-area preload/1.0'})
            with urlopen(request, timeout=35) as response:
                result = json.load(response)
            if result.get('remark') or not isinstance(result.get('elements'), list):
                raise ValueError('Incomplete Overpass response')
            if any(not isinstance(e, dict) for e in result['elements']):
                raise ValueError('Invalid OSM element')
            document = {'region': region, 'bounds': bounds, 'complete': True,
                        'downloaded_at': time.time(), 'provider': provider,
                        'osm_base': result.get('osm3s', {}).get('timestamp_osm_base'),
                        'elements': result['elements']}
            temporary = target.with_suffix('.partial')
            temporary.write_text(json.dumps(document))
            temporary.replace(target)
            print(f'{region}: complete, {len(result["elements"])} OSM elements', flush=True)
            return
        except Exception as error:
            print(f'{region}: provider failed ({type(error).__name__}: {getattr(error, "code", "")})', flush=True)
    raise RuntimeError(f'{region}: all providers failed; no snapshot marked complete')


def download_region(region, output):
    from math import ceil
    south, west, north, east = REGIONS[region]
    parts = output / (region + '-parts')
    parts.mkdir(parents=True, exist_ok=True)
    pieces = []
    for y in range(ceil((north-south)/.6)):
        for x in range(ceil((east-west)/.6)):
            bounds = tuple(round(v, 6) for v in (south+y*.6, west+x*.6,
                           min(north, south+(y+1)*.6), min(east, west+(x+1)*.6)))
            name = f'{region}-{x}-{y}'
            download(name, parts, bounds)
            pieces.append(json.loads((parts / (name+'.json')).read_text()))
            time.sleep(2)
    elements = {(e['type'], e['id']): e for p in pieces for e in p['elements']}
    document = {'region': region, 'bounds': REGIONS[region], 'complete': True,
                'downloaded_at': time.time(), 'osm_base': min(p['osm_base'] for p in pieces),
                'elements': list(elements.values())}
    target = output / (region+'.json')
    temporary = target.with_suffix('.partial')
    temporary.write_text(json.dumps(document))
    temporary.replace(target)
    print(f'{region}: combined complete snapshot, {len(elements)} elements', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--region', choices=list(REGIONS), action='append')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    for region in args.region or REGIONS:
        download_region(region, args.output)
