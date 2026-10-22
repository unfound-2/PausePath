-- Apply after 20261017170000_community_challenges.sql.
ALTER TABLE walking_communities ADD COLUMN request_id uuid;
CREATE UNIQUE INDEX community_create_request ON walking_communities(created_by, request_id);
ALTER TABLE walking_challenges ADD COLUMN shared_goal boolean NOT NULL DEFAULT false;
CREATE TABLE community_walks (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), community_id uuid NOT NULL REFERENCES walking_communities(id) ON DELETE CASCADE,
 created_by text NOT NULL, request_id uuid NOT NULL, title text NOT NULL, meeting_point text NOT NULL,
 route_description text NOT NULL, starts_at timestamptz NOT NULL, cancelled boolean NOT NULL DEFAULT false,
 UNIQUE(created_by, request_id)
);
CREATE TABLE community_walk_rsvps (
 walk_id uuid NOT NULL REFERENCES community_walks(id) ON DELETE CASCADE, user_id text NOT NULL,
 PRIMARY KEY(walk_id,user_id)
);
CREATE TABLE community_posts (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), community_id uuid NOT NULL REFERENCES walking_communities(id) ON DELETE CASCADE,
 user_id text NOT NULL, request_id uuid NOT NULL, body text NOT NULL CHECK(char_length(body) BETWEEN 1 AND 280),
 created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(user_id,request_id)
);
CREATE TABLE community_reactions (
 post_id uuid NOT NULL REFERENCES community_posts(id) ON DELETE CASCADE, user_id text NOT NULL,
 PRIMARY KEY(post_id,user_id)
);
DO $$ DECLARE t text; r text;
BEGIN
 FOREACH t IN ARRAY ARRAY['community_walks','community_walk_rsvps','community_posts','community_reactions'] LOOP
  EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
  EXECUTE format('REVOKE ALL ON TABLE %I FROM PUBLIC', t);
  FOREACH r IN ARRAY ARRAY['anon','authenticated'] LOOP
   IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname=r) THEN EXECUTE format('REVOKE ALL ON TABLE %I FROM %I',t,r); END IF;
  END LOOP;
 END LOOP;
END $$;
