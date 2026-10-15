from pyproj import Geod

GEOD = Geod(ellps='WGS84')

def distance(a,b): return GEOD.inv(a[0],a[1],b[0],b[1])[2]

def densify(coordinates):
    result = [coordinates[0]]
    total = 0.0
    for a,b in zip(coordinates, coordinates[1:]):
        length = distance(a,b)
        total += length
        if total > 100000: raise ValueError('Routes are limited to 100 km')
        if length < 0.01: continue
        count = int(length // 25)
        if count: result.extend(GEOD.npts(a[0],a[1],b[0],b[1],count))
        result.append(b)
    if total < 1: raise ValueError('Route must be at least one meter long')
    return result,total

def at_distance(coordinates, target):
    remaining = target
    for a,b in zip(coordinates,coordinates[1:]):
        azimuth,_,length = GEOD.inv(a[0],a[1],b[0],b[1])
        if remaining <= length:
            lon,lat,_ = GEOD.fwd(a[0],a[1],azimuth,remaining)
            return [lon,lat]
        remaining -= length
    return list(coordinates[-1])
