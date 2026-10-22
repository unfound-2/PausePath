-- Preserve progress when a goal is archived; API membership remains the access boundary.
ALTER TABLE walking_challenges ADD COLUMN IF NOT EXISTS archived_at timestamptz;
