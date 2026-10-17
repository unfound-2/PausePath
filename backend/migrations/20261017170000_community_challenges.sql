CREATE TABLE walking_communities (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL CHECK (char_length(name) BETWEEN 2 AND 60),
    invite_code text NOT NULL UNIQUE CHECK (char_length(invite_code) BETWEEN 4 AND 12),
    created_by text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE walking_community_members (
    community_id uuid NOT NULL REFERENCES walking_communities(id) ON DELETE CASCADE,
    user_id text NOT NULL,
    display_name text NOT NULL CHECK (char_length(display_name) BETWEEN 1 AND 32),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (community_id,user_id)
);
CREATE TABLE walking_challenges (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    community_id uuid NOT NULL REFERENCES walking_communities(id) ON DELETE CASCADE,
    name text NOT NULL CHECK (char_length(name) BETWEEN 2 AND 80),
    metric text NOT NULL CHECK (metric IN ('distance_km','walks','minutes','new_routes')),
    target numeric NOT NULL CHECK (target BETWEEN 1 AND 10000),
    created_by text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE walking_challenge_progress (
    challenge_id uuid NOT NULL REFERENCES walking_challenges(id) ON DELETE CASCADE,
    user_id text NOT NULL,
    amount numeric NOT NULL DEFAULT 0 CHECK (amount BETWEEN 0 AND 100000),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (challenge_id,user_id)
);
CREATE INDEX walking_challenges_community_created ON walking_challenges(community_id,created_at DESC);
CREATE INDEX walking_progress_leaderboard ON walking_challenge_progress(challenge_id,amount DESC);
DO $$ DECLARE table_name text; role_name text;
BEGIN
    FOREACH table_name IN ARRAY ARRAY['walking_communities','walking_community_members','walking_challenges','walking_challenge_progress'] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY',table_name);
        EXECUTE format('REVOKE ALL ON TABLE %I FROM PUBLIC',table_name);
        FOREACH role_name IN ARRAY ARRAY['anon','authenticated'] LOOP
            IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname=role_name) THEN
                EXECUTE format('REVOKE ALL ON TABLE %I FROM %I',table_name,role_name);
            END IF;
        END LOOP;
    END LOOP;
END $$;
