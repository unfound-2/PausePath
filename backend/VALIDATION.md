# Backend validation — 2026-10-15

- Local Python 3.9.6: **15 tests passed**, **4 PostGIS integration tests skipped** because Docker/PostgreSQL are not installed on this Mac.
- Tests cover hours/timezone/overnight boundaries, closures during breaks, geodesic markers and dateline handling, input validation, unauthenticated write rejection, route ETA with detours, unknown/closed hours and disconnected stops.
- The `osm-auth` browser helper bundles successfully; dependency installation reported zero vulnerabilities.
- OpenAPI was regenerated from the FastAPI application; whitespace checks passed.
- [GitHub Actions run 38693094843](https://github.com/unfound-2/PausePath/actions/runs/38693094843) **passed** on implementation commit `5a79cf5`, using Python 3.12 and PostGIS 16/3.5. It ran all 19 tests with the database configured, including confidence-trigger, cooldown, temporary-closure and metric-corridor checks, and confirmed the generated OpenAPI matches the committed schema.
- No production deployment, provider credential use, live OSM edits or paid Places requests were performed. OAuth login and live pedestrian-provider behavior require configured services for end-to-end validation.
- The Swift app is not connected to this backend yet. No iOS code changed in this increment.

## Supabase / Render / Mapbox increment

- Local verification: 23 tests passed; 5 PostGIS tests require the GitHub database service.
- Added mocked Mapbox category/session/error checks, no-store/authentication checks, ES256 Supabase token validation and server-managed role enforcement.
- Added a real private-schema/RLS integration check to the PostGIS suite.
- Render Blueprint and new-account setup instructions are included; no Supabase/Render resources or Mapbox credentials exist yet, so live deployment/provider validation remains pending.
