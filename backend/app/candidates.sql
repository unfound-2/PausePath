WITH route AS (
    SELECT ST_SetSRID(ST_GeomFromGeoJSON(%(route)s),4326) AS geom
), dumped AS (
    SELECT d.path[1] AS ordinal,d.geom,ST_Length(d.geom::geography) AS length_m
    FROM route CROSS JOIN LATERAL ST_DumpSegments(route.geom) d
), segments AS (
    SELECT *, coalesce(sum(length_m) OVER (ORDER BY ordinal ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0) AS start_m
    FROM dumped
), nearby AS (
    SELECT p.*,ST_Distance(p.geom::geography,ST_SetSRID(ST_MakePoint(%(lon)s,%(lat)s),4326)::geography) AS target_distance
    FROM pois p,route
    WHERE p.is_active AND p.category = ANY(%(categories)s)
      AND ST_DWithin(p.geom::geography,route.geom::geography,100)
      AND ST_DWithin(p.geom::geography,ST_SetSRID(ST_MakePoint(%(lon)s,%(lat)s),4326)::geography,200)
      AND coalesce(p.attributes->>'access','unknown') NOT IN ('private','customers')
      AND (NOT %(wheelchair)s OR p.attributes->>'wheelchair_accessible'='true')
)
SELECT p.id,p.name,p.category,p.confidence_score,p.operating_hours,p.attributes,p.closed_until,
       p.source,p.external_id,ST_AsGeoJSON(p.geom)::jsonb AS location,p.target_distance,
       nearest.start_m + nearest.fraction * nearest.length_m AS marker_m,
       ST_AsGeoJSON(ST_Transform(ST_LineInterpolatePoint(nearest.metric_geom,nearest.fraction),%(projection)s,4326))::jsonb AS attachment,
       (%(weights)s::jsonb->>p.category)::float8*p.confidence_score/(1+p.target_distance) AS score
FROM nearby p
CROSS JOIN LATERAL (
    SELECT s.*,ST_Transform(s.geom,%(projection)s) AS metric_geom,
           ST_LineLocatePoint(ST_Transform(s.geom,%(projection)s),ST_Transform(p.geom,%(projection)s)) AS fraction
    FROM segments s
    -- Restrict occurrences to this break's segment neighborhood. Self-crossing and
    -- out-and-back geometries must not project all stops onto their first occurrence.
    WHERE s.start_m+s.length_m >= %(target)s-300 AND s.start_m <= %(target)s+300
    ORDER BY ST_Distance(ST_Transform(s.geom,%(projection)s),ST_Transform(p.geom,%(projection)s)),abs(s.start_m-%(target)s),s.ordinal
    LIMIT 1
) nearest
ORDER BY score DESC,p.id
LIMIT 12;
