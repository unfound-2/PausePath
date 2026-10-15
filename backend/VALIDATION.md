# Backend validation — 2026-10-15

- Local Python 3.9.6: **15 tests passed**, **4 PostGIS integration tests skipped** because Docker/PostgreSQL are not installed on this Mac.
- Tests cover hours/timezone/overnight boundaries, closures during breaks, geodesic markers and dateline handling, input validation, unauthenticated write rejection, route ETA with detours, unknown/closed hours and disconnected stops.
- The `osm-auth` browser helper bundles successfully; dependency installation reported zero vulnerabilities.
- OpenAPI was regenerated from the FastAPI application; whitespace checks passed.
- GitHub Actions provisions PostGIS 16/3.5 to run the SQL confidence-trigger, cooldown, temporary-closure and metric-corridor integration checks. Its run is the authority for database validation.
- No production deployment, provider credential use, live OSM edits or paid Places requests were performed. OAuth login and live pedestrian-provider behavior require configured services for end-to-end validation.
- The Swift app is not connected to this backend yet. No iOS code changed in this increment.
