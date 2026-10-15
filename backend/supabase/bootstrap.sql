-- Fresh-project bootstrap generated from backend/migrations. No credentials.
CREATE SCHEMA IF NOT EXISTS pausepath;
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA extensions;
SET LOCAL search_path TO pausepath, extensions;
SELECT pg_advisory_xact_lock(52908131);
CREATE TABLE schema_migrations (name text PRIMARY KEY, sha256 text NOT NULL, applied_at timestamptz DEFAULT now());

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE pois (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source text NOT NULL CHECK (source IN ('osm', 'community')),
    external_id text NOT NULL,
    name text,
    category text NOT NULL CHECK (category IN ('bench','toilet','drinking_water','cafe')),
    geom geometry(Point,4326) NOT NULL,
    is_active boolean NOT NULL DEFAULT true,
    confidence_score double precision NOT NULL DEFAULT 0.6 CHECK (confidence_score BETWEEN 0 AND 1),
    operating_hours jsonb,
    attributes jsonb NOT NULL DEFAULT '{}',
    closed_until timestamptz,
    source_updated_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(source, external_id),
    CHECK (ST_X(geom) BETWEEN -180 AND 180 AND ST_Y(geom) BETWEEN -90 AND 90)
);
CREATE INDEX pois_geography_idx ON pois USING gist ((geom::geography));
CREATE INDEX pois_category_active_idx ON pois(category) WHERE is_active;

CREATE TABLE poi_reports (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    poi_id uuid NOT NULL REFERENCES pois(id),
    user_id text NOT NULL,
    report_type text NOT NULL CHECK (report_type IN ('confirm_exists','broken_or_empty','temporarily_closed','removed')),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    request_id uuid NOT NULL,
    payload_hash text NOT NULL,
    UNIQUE(user_id,request_id)
);
CREATE INDEX poi_reports_recent_idx ON poi_reports(poi_id,created_at DESC,id);
CREATE INDEX poi_reports_user_idx ON poi_reports(user_id,created_at DESC);

CREATE TABLE poi_suggestions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id text NOT NULL,
    request_id uuid NOT NULL,
    payload_hash text NOT NULL,
    name text,
    category text NOT NULL CHECK (category IN ('bench','toilet','drinking_water','cafe')),
    geom geometry(Point,4326) NOT NULL,
    attributes jsonb NOT NULL DEFAULT '{}',
    status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected')),
    poi_id uuid REFERENCES pois(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(user_id,request_id)
);
CREATE TABLE moderation_audit (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_id text NOT NULL,
    action text NOT NULL,
    subject_id uuid NOT NULL,
    evidence text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE osm_edit_queue (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    poi_id uuid NOT NULL REFERENCES pois(id),
    action text NOT NULL CHECK (action IN ('add','remove')),
    payload jsonb NOT NULL,
    verified_by text NOT NULL,
    evidence text NOT NULL,
    status text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','claimed','submitted','needs_reconciliation')),
    changeset_id bigint,
    claimed_by text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX osm_edit_pending_idx ON osm_edit_queue(poi_id,action)
    WHERE status IN ('queued','claimed','needs_reconciliation');
-- Store only the Google identifier. Live provider content is never imported into OSM/community data.
CREATE TABLE commercial_place_links (
    poi_id uuid PRIMARY KEY REFERENCES pois(id),
    google_place_id text NOT NULL,
    linked_by text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- Serialize votes per POI before checking limits or updating confidence.
CREATE FUNCTION guard_poi_report() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM pois WHERE id=NEW.poi_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown POI' USING ERRCODE='23503'; END IF;
    NEW.created_at := clock_timestamp();
    IF EXISTS (SELECT 1 FROM poi_reports WHERE poi_id=NEW.poi_id AND user_id=NEW.user_id
               AND created_at > NEW.created_at - interval '24 hours') THEN
        RAISE EXCEPTION 'One report per user per POI per 24 hours' USING ERRCODE='23505';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER poi_report_guard BEFORE INSERT ON poi_reports
FOR EACH ROW EXECUTE FUNCTION guard_poi_report();

CREATE FUNCTION update_poi_confidence(target_poi_id uuid) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    positives integer; negatives integer; negative_streak integer; score double precision;
    latest_temporary timestamptz; latest_confirmation timestamptz;
BEGIN
    PERFORM 1 FROM pois WHERE id=target_poi_id FOR UPDATE;
    -- Only the newest vote from each identity in 30 days counts. A prolific user
    -- cannot stack votes, even after the 24-hour submission cooldown.
    WITH votes AS (
        SELECT DISTINCT ON (user_id) report_type,created_at,id FROM poi_reports
        WHERE poi_id=target_poi_id AND created_at > now()-interval '30 days'
        ORDER BY user_id,created_at DESC,id DESC
    ) SELECT count(*) FILTER (WHERE report_type='confirm_exists'),
             count(*) FILTER (WHERE report_type IN ('broken_or_empty','removed')),
             max(created_at) FILTER (WHERE report_type='temporarily_closed'),
             max(created_at) FILTER (WHERE report_type='confirm_exists')
      INTO positives,negatives,latest_temporary,latest_confirmation FROM votes;
    score := greatest(0.0,least(1.0,0.6+positives*0.1-negatives*0.2));
    WITH latest_users AS (
        SELECT DISTINCT ON (user_id) report_type,created_at,id FROM poi_reports
        WHERE poi_id=target_poi_id AND created_at > now()-interval '30 days'
        ORDER BY user_id,created_at DESC,id DESC
    ), latest_three AS (SELECT * FROM latest_users ORDER BY created_at DESC,id DESC LIMIT 3)
    SELECT count(*) FILTER (WHERE report_type IN ('broken_or_empty','removed'))
      INTO negative_streak FROM latest_three;
    UPDATE pois SET confidence_score=score,
        is_active=CASE WHEN score < 0.3 AND negative_streak=3 THEN false ELSE is_active END,
        closed_until=CASE WHEN latest_temporary IS NOT NULL AND
             (latest_confirmation IS NULL OR latest_temporary > latest_confirmation)
             THEN latest_temporary+interval '6 hours' ELSE NULL END,
        updated_at=now() WHERE id=target_poi_id;
    -- Inactive POIs require moderator review; imports/old votes never reactivate them.
END $$;
CREATE FUNCTION report_confidence_trigger() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN PERFORM update_poi_confidence(NEW.poi_id); RETURN NEW; END $$;
CREATE TRIGGER poi_report_confidence AFTER INSERT ON poi_reports
FOR EACH ROW EXECUTE FUNCTION report_confidence_trigger();

CREATE TABLE api_request_receipts (
    user_id text NOT NULL, request_id uuid NOT NULL, payload_hash text NOT NULL,
    response jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(user_id,request_id)
);
CREATE TABLE api_rate_buckets (
    user_id text NOT NULL, action text NOT NULL, window_start timestamptz NOT NULL,
    count integer NOT NULL DEFAULT 1,
    PRIMARY KEY(user_id,action,window_start)
);

INSERT INTO schema_migrations(name,sha256) VALUES ('001_initial.sql','198d2d0f4e11b38f7922580f3a74cbfea60a14020232dc7b5a17b4be8771b4b3');
-- The API uses a direct database connection as table owner. No client Data API
-- policies are granted: all writes must go through authenticated FastAPI routes.
DO $$
DECLARE table_name text; role_name text;
BEGIN
    FOREACH table_name IN ARRAY ARRAY['pois','poi_reports','poi_suggestions',
        'moderation_audit','osm_edit_queue','commercial_place_links',
        'api_request_receipts','api_rate_buckets','schema_migrations'] LOOP
        -- Integration fixtures can apply migrations without the migration ledger.
        IF to_regclass(format('%I.%I',current_schema(),table_name)) IS NULL THEN CONTINUE; END IF;
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY',table_name);
        EXECUTE format('REVOKE ALL ON TABLE %I FROM PUBLIC',table_name);
        FOREACH role_name IN ARRAY ARRAY['anon','authenticated'] LOOP
            IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname=role_name) THEN
                EXECUTE format('REVOKE ALL ON TABLE %I FROM %I',table_name,role_name);
            END IF;
        END LOOP;
    END LOOP;
    EXECUTE format('REVOKE ALL ON FUNCTION %I.update_poi_confidence(uuid) FROM PUBLIC', current_schema());
    EXECUTE format('REVOKE ALL ON FUNCTION %I.guard_poi_report() FROM PUBLIC', current_schema());
    EXECUTE format('REVOKE ALL ON FUNCTION %I.report_confidence_trigger() FROM PUBLIC', current_schema());
END $$;
-- Keep the legacy Google-ID table for migration compatibility, but no endpoint
-- uses it. Mapbox data (including IDs) is request-scoped and never stored here.

INSERT INTO schema_migrations(name,sha256) VALUES ('002_api_only_access.sql','4b4348ae149a0589740e1912579a5175e704a5609995dee167da76a5216644e5');

-- Lock down the private schema and function resolution for this deployment.
REVOKE ALL ON SCHEMA pausepath FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pausepath FROM PUBLIC, anon, authenticated;
ALTER FUNCTION pausepath.guard_poi_report() SET search_path TO pausepath, extensions;
ALTER FUNCTION pausepath.update_poi_confidence(uuid) SET search_path TO pausepath, extensions;
ALTER FUNCTION pausepath.report_confidence_trigger() SET search_path TO pausepath, extensions;
