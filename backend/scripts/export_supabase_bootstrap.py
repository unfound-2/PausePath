"""Export existing checksummed API migrations for a fresh Supabase project.
Run this only on an empty PausePath schema. Render then recognizes the ledger.
"""
import hashlib
from pathlib import Path
root = Path(__file__).resolve().parents[1]
parts = ["""-- Fresh-project bootstrap generated from backend/migrations. No credentials.
CREATE SCHEMA IF NOT EXISTS pausepath;
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA extensions;
SET LOCAL search_path TO pausepath, extensions;
SELECT pg_advisory_xact_lock(52908131);
CREATE TABLE schema_migrations (name text PRIMARY KEY, sha256 text NOT NULL, applied_at timestamptz DEFAULT now());
"""]
for path in sorted((root / 'migrations').glob('*.sql')):
    source = path.read_text()
    parts.append(source)
    parts.append("INSERT INTO schema_migrations(name,sha256) VALUES ('%s','%s');" %
                 (path.name, hashlib.sha256(source.encode()).hexdigest()))
parts.append("""
-- Lock down the private schema and function resolution for this deployment.
REVOKE ALL ON SCHEMA pausepath FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pausepath FROM PUBLIC, anon, authenticated;
ALTER FUNCTION pausepath.guard_poi_report() SET search_path TO pausepath, extensions;
ALTER FUNCTION pausepath.update_poi_confidence(uuid) SET search_path TO pausepath, extensions;
ALTER FUNCTION pausepath.report_confidence_trigger() SET search_path TO pausepath, extensions;
""")
(root / 'supabase/bootstrap.sql').write_text('\n'.join(parts))
