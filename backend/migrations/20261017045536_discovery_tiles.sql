CREATE TABLE IF NOT EXISTS discovery_tiles (
    x integer NOT NULL CHECK (x >= 0 AND x < 18000),
    y integer NOT NULL CHECK (y >= 0 AND y < 9000),
    state text NOT NULL DEFAULT 'queued' CHECK (state IN ('queued','loading','ready','unavailable')),
    fetched_at timestamptz,
    requested_at timestamptz NOT NULL DEFAULT now(),
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 6),
    PRIMARY KEY (x,y)
);
CREATE INDEX IF NOT EXISTS discovery_tiles_pending ON discovery_tiles(next_attempt_at, requested_at);
CREATE TABLE IF NOT EXISTS discovery_budget (id integer PRIMARY KEY CHECK (id=1), next_job_at timestamptz NOT NULL DEFAULT now());
INSERT INTO discovery_budget(id) VALUES (1) ON CONFLICT DO NOTHING;
ALTER TABLE discovery_tiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE discovery_budget ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON discovery_tiles, discovery_budget FROM PUBLIC;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN
        REVOKE ALL ON discovery_tiles, discovery_budget FROM anon;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN
        REVOKE ALL ON discovery_tiles, discovery_budget FROM authenticated;
    END IF;
END $$;
