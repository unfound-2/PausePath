"""Filter downloaded Geofabrik OSM PBF extracts into metro amenity snapshots.

Requires osmium==4.1.1 in the administrative environment only. Reads files in
passes with native ID filters, avoiding a planet-sized node-location cache.
Source extracts must collectively cover the requested envelope; list any
geographic exclusions in the resulting coverage documentation.
"""
import argparse
import json
import time
from pathlib import Path
import osmium
from download_test_metros import REGIONS


def extract(region, files, output):
    south, west, north, east = REGIONS[region]
    def inside(lon, lat): return west <= lon <= east and south <= lat <= north
    def objects(entities, filter):
        for filename in files:
            yield from osmium.FileProcessor(str(filename), entities).with_filter(filter())
    amenities = ('bench', 'toilets', 'drinking_water', 'cafe')
    tag_filter = lambda: osmium.filter.TagFilter(*[('amenity', a) for a in amenities])
    elements, ways, relations, tags_by_id = {}, {}, {}, {}
    for obj in objects(osmium.osm.ALL, tag_filter):
        kind = 'node' if obj.is_node() else 'way' if obj.is_way() else 'relation'
        key = (kind, obj.id)
        tags = dict(obj.tags)
        if obj.is_node():
            if obj.location.valid() and inside(obj.lon, obj.lat):
                elements[key] = dict(type=kind,id=obj.id,lon=obj.lon,lat=obj.lat,tags=tags)
        elif obj.is_way():
            ways[obj.id] = [n.ref for n in obj.nodes]
            tags_by_id[key] = tags
        elif obj.is_relation():
            relations[obj.id] = [(m.type,m.ref) for m in obj.members]
            tags_by_id[key] = tags
    print(region, 'amenity candidates collected', len(elements)+len(tags_by_id), flush=True)
    # Resolve nested relations, then member ways, then only needed node locations.
    for depth in range(10):
        missing = {ref for members in relations.values() for kind, ref in members
                   if kind == 'r' and ref not in relations}
        if not missing: break
        before = len(relations)
        for obj in objects(osmium.osm.RELATION, lambda: osmium.filter.IdFilter(missing)):
            relations[obj.id] = [(m.type,m.ref) for m in obj.members]
        if len(relations) == before: raise ValueError('Unresolved relation members')
    else: raise ValueError('Relation nesting exceeds limit')
    missing_ways = {ref for members in relations.values() for kind,ref in members if kind=='w'} - ways.keys()
    if missing_ways:
        for obj in objects(osmium.osm.WAY, lambda: osmium.filter.IdFilter(missing_ways)):
            ways[obj.id] = [n.ref for n in obj.nodes]
    node_ids = {ref for refs in ways.values() for ref in refs}
    node_ids.update(ref for members in relations.values() for kind,ref in members if kind=='n')
    locations = {}
    for obj in objects(osmium.osm.NODE, lambda: osmium.filter.IdFilter(node_ids)):
        if obj.location.valid(): locations[obj.id] = (obj.lon,obj.lat)
    def coords(kind, ident, seen=None):
        seen = set() if seen is None else seen
        if (kind,ident) in seen: return []
        seen.add((kind,ident))
        if kind == 'n': return [locations[ident]] if ident in locations else []
        if kind == 'w': return [locations[n] for n in ways.get(ident,[]) if n in locations]
        return [p for k,ref in relations.get(ident,[]) for p in coords(k,ref,seen)]
    missing_geometry = 0
    for (kind,ident), tags in tags_by_id.items():
        points = coords(kind[0], ident)
        if not points:
            missing_geometry += 1
            continue
        lon = (min(p[0] for p in points)+max(p[0] for p in points))/2
        lat = (min(p[1] for p in points)+max(p[1] for p in points))/2
        if inside(lon,lat):
            elements[(kind,ident)] = dict(type=kind,id=ident,center=dict(lon=lon,lat=lat),tags=tags)
    if missing_geometry: raise ValueError(f'{missing_geometry} amenity geometries unresolved')
    timestamps = []
    for filename in files:
        reader = osmium.io.Reader(str(filename))
        timestamps.append(reader.header().get('osmosis_replication_timestamp'))
        reader.close()
    doc = dict(region=region,bounds=REGIONS[region],complete=True,downloaded_at=time.time(),
               osm_base=min(timestamps),source_files=[p.name for p in files],elements=list(elements.values()))
    output.parent.mkdir(parents=True,exist_ok=True)
    temp = output.with_suffix('.partial')
    temp.write_text(json.dumps(doc))
    temp.replace(output)
    print(region,'complete:',len(elements),'amenities; OSM',doc['osm_base'],flush=True)


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--region',choices=list(REGIONS),required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('files',type=Path,nargs='+')
    args=parser.parse_args()
    extract(args.region,args.files,args.output)
