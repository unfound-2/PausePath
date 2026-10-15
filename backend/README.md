# PausePath micro-amenity backend

FastAPI + PostgreSQL 16/PostGIS 3.5, EPSG:4326. The service ingests baseline amenities, accepts authenticated community reports, curates breaks along a caller-supplied walking/running route, and queues independently reviewed OSM contributions. The selected deployment is Supabase PostGIS/Auth + Render, with request-scoped Mapbox Search metadata. Follow [DEPLOYMENT.md](DEPLOYMENT.md) to create and configure the services. The Swift app is not yet wired to these endpoints.

## Run locally

Requirements: Docker Compose, or Python 3.9+ and a PostgreSQL/PostGIS database. Python 3.12 is used in the container and CI. No real user data, API credentials or OAuth tokens are included.

```sh
cd backend
cp .env.example .env
# Fill in identity-provider and pedestrian-router settings; keep .env untracked.
docker compose up --build
```

Compose runs the checksummed migration job before the API. PostgreSQL and HTTP are bound to localhost. The sample database password is only for local development; replace it and DATABASE_URL together for other environments. For hosted deployments use a private database, TLS, separate migration/runtime DB roles, a secret manager and an ingress body-size limit (1 MB). Restrict the runtime role to the tables/functions it needs; do not give it schema/extension administration privileges.

Without Docker:

```sh
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
# Export the variables from .env through your environment manager.
.venv/bin/python scripts/migrate.py
.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000 --no-access-log
```

Interactive schema: `/docs`. Machine-readable schema: `/openapi.json`, with a checked-in copy at [openapi.json](openapi.json). Regenerate with `python scripts/export_openapi.py`.

## Identity and endpoint contract

Supply `Authorization: Bearer <JWT>` from your configured identity provider. RS256/ES256 signatures, expiry, issuer, audience and subject are checked against HTTPS JWKS. `user_id` comes exclusively from the verified subject, never from a request body. Privileged roles are read from server-managed `app_metadata.roles` in Supabase mode, or top-level `roles` for a generic identity provider. User-editable metadata never grants roles. There is no anonymous-write mode, token mint endpoint or development authentication bypass.

| Endpoint | Role | Purpose |
| --- | --- | --- |
| `GET /health`, `GET /ready` | public | Process and database readiness |
| `POST /api/v1/routes/curate` | authenticated | GeoJSON route + selected breaks and access paths |
| `GET /api/v1/pois/{id}` | authenticated | POI details, confidence, hours and provenance |
| `POST /api/v1/reports` | authenticated | Status report or new-location suggestion |
| `POST /api/v1/admin/ingest/osm` | admin | Bounded Overpass baseline upsert |
| `POST /api/v1/suggestions/{id}/review` | reviewer | Approve/reject a suggestion from another user |
| `PATCH /api/v1/pois/{id}/review` | reviewer | Reviewed activation, normalized hours and attributes |
| `POST /api/v1/commercial/mapbox/category` | authenticated | Viewport café/food discovery |
| `POST /api/v1/commercial/mapbox/suggest` | authenticated | Session-based business autocomplete |
| `POST /api/v1/commercial/mapbox/retrieve` | authenticated | Selected business metadata |
| `POST /api/v1/osm/queue`, `GET /api/v1/osm/queue` | reviewer | Queue/list independently verified edits |
| `POST /api/v1/osm/queue/{id}/claim` | reviewer | Exclusive submission claim |
| `PUT /api/v1/osm/queue/{id}/changeset/{changeset_id}` | reviewer | Record changeset before upload |
| `POST /api/v1/osm/queue/{id}/receipt` | reviewer | Record result or require reconciliation |

See [examples.json](examples.json) for executable request bodies. Responses reject invalid coordinates, naive datetimes, unsupported categories, duplicate category priorities and excess fields. Reporting requests require a client-generated UUID `request_id`; exact retries return the stored receipt. Reusing the key for a different payload returns 409. A receipt is a snapshot, not the current POI state; GET the POI for current confidence.

## Spatial curation and access

1. Validate the supplied LineString and densify geodesic segments to at most 25 m; limit routes to 100 km and at most 50 targets.
2. Build markers at the requested interval, excluding a target exactly at the finish. Distances are WGS84 geodesic meters, not degree buffers.
3. PostGIS uses indexed `ST_DWithin(p.geom::geography, route::geography, 100)` for the corridor and a separate 200 m target radius.
4. Project each candidate onto nearby route segments in a local azimuthal-equidistant projection. Each returned `distance_marker_meters` is the actual along-route attachment marker, distinct from the ideal target marker. Densification keeps subsegment interpolation error small; precision cannot exceed the input route/provider geometry.
5. Rank using `priority_weight * confidence_score / (1 + target_distance_meters)`. Priority weights descend from the number of chosen categories to one. Resolve ties by stable POI ID.
6. Require an active, public-or-unknown-access POI; exclude private/customer-only access and area centroids. Explicit wheelchair requirements require known-positive metadata.
7. Ask a dedicated **pedestrian OSRM graph** for outbound and return connectors. Reject unroutable, excessively snapped (>25 m) or over-limit connectors. A nearby point across a fence/river is not accepted solely on proximity. Tiny router snap offsets are explicit in connector geometry; graph and surveyed-entrance quality still determine real access accuracy.
8. Compute ETA using selected speed (defaults: walk 1.2 m/s, run 2.5 m/s), previous detours and prior break durations. Exclude crowd temporary closures and closed hours throughout the break. Unknown hours are excluded by default; clients can explicitly opt in and get `hours_status: unknown`.
9. Select at most one candidate per target without reusing a POI; preserve increasing route markers. This is greedy breakpoint curation, not a globally optimal route rewrite or a verified maximum-seating-gap guarantee. Return unfilled targets instead of silently expanding radii or changing intervals.

The GeoJSON Feature's geometry is the **base route**, unchanged. `geometry_includes_detours: false` is explicit. `break_points[].connector` provides outbound/return LineStrings and distances; navigation must traverse those connectors at the returned markers. `total_distance_with_detours_meters` includes them. The caller remains responsible for providing a walkable base route.

Bounds: 12 ranked candidates per marker, 60 connector checks, and a 45-second search budget (an in-flight HTTP call may add up to its timeout). Missing/failed checks produce unfilled targets and warnings. Configure service timeouts accordingly. No provider fallback silently substitutes driving directions.

## Hours format

Raw OSM `opening_hours` is preserved, but only unambiguous `24/7` is directly recognized. Complex raw rules remain unknown until normalized; they are never assumed open. Reviewers can provide:

```json
{"timezone":"America/Chicago","weekly":[{"weekday":0,"open":"09:00","close":"17:00"}],"exceptions":{"2026-12-25":[]}}
```

Weekdays use Monday=0. Overnight intervals such as 22:00–02:00 are supported. Local wall-clock evaluation uses IANA timezone rules, including DST. Date exceptions override weekly/overnight rules. Alternatively use `windows: [{start,end}]` with timezone-aware absolute timestamps and explicit `valid_from`/`valid_until`; dates outside that horizon remain unknown. Malformed/unsupported data fails to unknown. A complete OSM holiday-hours parser is not bundled, and a reviewer must not substitute guessed hours.

## Ingestion and provider separation

Overpass ingests nodes, ways and relations for bench, toilets, drinking_water and cafe. IDs are namespaced (`node/123`, `way/123`) so object types cannot collide. Area centers are stored for discovery but excluded from break curation until a usable entrance is surveyed. Upserts preserve crowd confidence/inactivation and reviewed hours/attributes. No records are deleted merely because a partial Overpass response omits them; provider remarks reject the batch.

Mapbox Search Box supplies temporary category/search results and business metadata through authenticated endpoints. Results retain provider attribution and use no-store responses; no Mapbox data or identifiers enter the persistent POI store or OSM queue. Supported categories are `coffee` and `food_and_drink`; suggestions and selected detail retrieval use a shared UUIDv4 session token. Optional hours/status metadata remains provider data: active status never implies open at arrival. Curation still uses OSM/community records. See [deployment and provider details](DEPLOYMENT.md) for configuration, coverage, client handling and limits.

## Reporting trust model

The SQL trigger calls `update_poi_confidence(poi_id)` inside the insert transaction. Row locking serializes reports for a POI. A distinct authenticated identity can report the same POI only once per rolling 24 hours. Only its latest vote in 30 days contributes: baseline 0.6, +0.1 per confirmation, −0.2 per broken/removed vote, clamped to [0,1]. Three latest distinct-user negative votes plus score below 0.3 deactivate the POI. Confirmation reports do not automatically reactivate an inactive POI; a reviewer must do so explicitly.

Temporary closure reports exclude a stop for six hours unless superseded by a newer confirmation; they do not permanently erase it. Suggestions stay outside the route pool until a different reviewer approves them. API rate limits are database-backed (10 reporting attempts/minute, 60 accepted reports/suggestions per day). Restrict identity creation upstream: these controls reduce duplicate voting, but do not solve coordinated fake accounts or prove that a report is true.

Run `python scripts/maintenance.py` daily to refresh expiring vote scores and prune old rate buckets. Idempotency receipts, reports and moderation audit records are retained; set a documented retention/deletion policy for production.

## OSM OAuth and edit queue

The [osm-client](osm-client/client.js) uses `osm-auth` 3.x OAuth 2.0. Configure an exact HTTPS redirect URI, `read_prefs write_api` scope and an independent reviewer login. A browser host needs bundling (`npm install && npm run build`) and same-origin serving with the API (no permissive CORS is enabled). OSM tokens stay in the browser; PausePath stores queue/changeset receipts, not OAuth tokens.

Queueing requires reviewer evidence from an independent survey. Only active community additions and inactive existing OSM nodes are eligible. Reviewers must inspect for duplicates and confirm the final edit before calling `submitReviewedEdit`; there is no background publisher. Commercial provider data must never be used as OSM edit evidence.

The helper claims the queue item exclusively, fetches the current OSM node/version for removals, creates a survey changeset, records its ID before uploading, uploads the diff and closes the changeset. Removal retires the `amenity` tag to `disused:amenity`, preserving node geometry, topology and other tags; it does not indiscriminately delete nodes. Conflicting lifecycle tags/versions require manual review. Ways and relations require manual OSM editing.

Uncertain uploads remain `claimed` or `needs_reconciliation`. **Never blindly retry them.** An operator must inspect the changeset in OSM and the queue/audit record, reconcile the created node identity back to the community record, and resolve the queue state through a controlled database migration or operator workflow. Receipts are reviewer-reported, not independent proof of OSM acceptance. A fully staffed reconciliation/admin UI is future operational work. No OSM writes are made during installation/tests.

References: [Overpass baseline queries](https://wiki.openstreetmap.org/wiki/Overpass_API/Overpass_API_by_Example), [PostGIS meter queries](https://postgis.net/documentation/tips/st-dwithin/), [osm-auth](https://github.com/osmlab/osm-auth), [OSM API changesets](https://wiki.openstreetmap.org/wiki/API_v0.6).

## Verification

```sh
python -m pytest tests
# To include SQL/trigger/spatial integration checks, point to an isolated *_test DB:
TEST_DATABASE_URL=postgresql://.../pausepath_test python -m pytest tests
```

Database tests roll back their schema and data and refuse database names that do not end in `_test`. GitHub Actions provisions PostGIS and runs both layers. Local unit/API results and limitations are recorded in [VALIDATION.md](VALIDATION.md). See [connected iOS systems](../docs/CONNECTED_SYSTEMS.md) for the Swift integration and its validation limits. No OSM publication or authenticated paid-provider acceptance test is implied by automated tests.
