-- Map viewport reads use geometry, while route corridors use geography.
CREATE INDEX IF NOT EXISTS pois_active_geom_idx ON pois USING gist (geom) WHERE is_active;
ANALYZE pois;
