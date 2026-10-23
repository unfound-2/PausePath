-- API-only social directory. Opt-in discovery never publishes locations or Health data.
CREATE TABLE social_profiles (
 user_id text PRIMARY KEY, id uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),
 username text NOT NULL UNIQUE CHECK(username ~ '^[a-z0-9_]{3,24}$'),
 discoverable boolean NOT NULL DEFAULT false, allow_requests boolean NOT NULL DEFAULT true,
 allow_walk_invites boolean NOT NULL DEFAULT true,
 notify_invites boolean NOT NULL DEFAULT true, notify_walks boolean NOT NULL DEFAULT true,
 notify_goals boolean NOT NULL DEFAULT true
);
CREATE INDEX social_profiles_discovery ON social_profiles(username text_pattern_ops) WHERE discoverable AND allow_requests;
CREATE TABLE friendships (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), requester text NOT NULL REFERENCES social_profiles(user_id) ON DELETE CASCADE,
 recipient text NOT NULL REFERENCES social_profiles(user_id) ON DELETE CASCADE,
 status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','accepted')),
 created_at timestamptz NOT NULL DEFAULT now(), CHECK(requester<>recipient)
);
CREATE UNIQUE INDEX friendships_pair ON friendships(least(requester,recipient),greatest(requester,recipient));
CREATE INDEX friendships_recipient ON friendships(recipient,status);
CREATE INDEX friendships_requester ON friendships(requester,status);
CREATE TABLE user_blocks (
 user_id text NOT NULL REFERENCES social_profiles(user_id) ON DELETE CASCADE,
 target_id text NOT NULL REFERENCES social_profiles(user_id) ON DELETE CASCADE,
 PRIMARY KEY(user_id,target_id), CHECK(user_id<>target_id)
);
CREATE INDEX user_blocks_target ON user_blocks(target_id,user_id);
ALTER TABLE walking_challenges ADD COLUMN completion_notified_at timestamptz;
ALTER TABLE community_walks ADD COLUMN route_snapshot jsonb;
ALTER TABLE community_walks ADD COLUMN meeting_location jsonb;
CREATE INDEX community_walks_upcoming ON community_walks(community_id,starts_at) WHERE NOT cancelled;
CREATE TABLE walk_invitations (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), walk_id uuid NOT NULL REFERENCES community_walks(id) ON DELETE CASCADE,
 sender text NOT NULL REFERENCES social_profiles(user_id) ON DELETE CASCADE,
 recipient text NOT NULL REFERENCES social_profiles(user_id) ON DELETE CASCADE,
 status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','accepted','declined')),
 created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(walk_id,recipient)
);
CREATE INDEX walk_invitations_sender ON walk_invitations(sender,recipient);
CREATE INDEX walk_invitations_recipient ON walk_invitations(recipient,status);
CREATE TABLE user_notifications (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id text NOT NULL REFERENCES social_profiles(user_id) ON DELETE CASCADE,
 actor_id text, category text NOT NULL CHECK(category IN ('invites','walks','goals')),
 message text NOT NULL, community_id uuid REFERENCES walking_communities(id) ON DELETE CASCADE,
 walk_id uuid REFERENCES community_walks(id) ON DELETE CASCADE,
 created_at timestamptz NOT NULL DEFAULT now(), read_at timestamptz
);
CREATE INDEX user_notifications_inbox ON user_notifications(user_id,created_at DESC);
CREATE INDEX user_notifications_community ON user_notifications(community_id);
CREATE INDEX user_notifications_walk ON user_notifications(walk_id);
DO $$ DECLARE t text; r text;
BEGIN
 FOREACH t IN ARRAY ARRAY['social_profiles','friendships','user_blocks','walk_invitations','user_notifications'] LOOP
  EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY',t);
  EXECUTE format('REVOKE ALL ON TABLE %I FROM PUBLIC',t);
  FOREACH r IN ARRAY ARRAY['anon','authenticated'] LOOP
   IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname=r) THEN EXECUTE format('REVOKE ALL ON TABLE %I FROM %I',t,r); END IF;
  END LOOP;
 END LOOP;
END $$;
