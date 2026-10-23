# Current free Render startup

Use `python scripts/start.py` as the Docker command and `/ready` as the health check. Startup applies every checked-in migration transactionally, checks stored checksums, and only starts Uvicorn after migrations succeed. This works on the free instance without a paid pre-deploy hook. `PORT` defaults to 10000. Database migration credentials stay in Render (`MIGRATION_DATABASE_URL` when separately configured, otherwise `DATABASE_URL`).

This command replaces any older explicit Uvicorn override in the Render dashboard; changing only the Dockerfile does not replace a saved override. An unapplied community migration caused create/join/list requests to fail despite `/health` returning OK. `/ready` now checks the community tables as well as POIs. A schema failure returns a recoverable 503 without SQL details.

# Deploy PausePath: Supabase + Render + Mapbox

This is the selected deployment path. Render runs the existing Python API; Supabase provides Postgres/PostGIS and Auth. No cloud resources have been created yet. Supabase Edge Functions are not a drop-in host for this Python/psycopg service; moving there would require a separate implementation.

## 1. Create Supabase

1. Create a Supabase project and save its database password in your password manager. Choose a region close to your intended Render service.
2. In Database → Extensions, enable **PostGIS in the `extensions` schema**. Do not install it in `public`. The migration runner also creates it if absent, using the configured extension schema.
3. In project connection settings, copy the **session pooler** URI (port 5432). Use its exact hostname and username (`postgres.PROJECT_REF`), database and URL-encoded password. Append `?sslmode=require` (or `&sslmode=require` if it already has parameters). Never use the Supabase publishable or service-role API key as a database password. Direct connections are also supported when IPv6 connectivity is available.
4. Under Auth, configure your intended sign-in method and an **asymmetric ES256 or RS256 signing key**. Legacy HS256 signing is deliberately unsupported by this API. Use these values:
   - `AUTH_ISSUER=https://PROJECT_REF.supabase.co/auth/v1`
   - `AUTH_JWKS_URL=https://PROJECT_REF.supabase.co/auth/v1/.well-known/jwks.json`
   - `AUTH_AUDIENCE=authenticated`
   - `AUTH_ROLES_SOURCE=app_metadata`
5. Keep the `pausepath` schema out of Supabase's **exposed Data API schemas**. Migrations create the app tables there and enable RLS with no client policies. The iOS client calls Render with its Supabase user access token; it does not write directly through the Data API.

The initial runtime connection uses the migrating table-owner account; this intentionally bypasses RLS for server-side operations. All end-user authorization is enforced by FastAPI. Keep this connection string server-only. For stronger production isolation, provision a dedicated runtime role with only required table/function privileges and explicit RLS policies before replacing it; do not point the service at `anon`/`authenticated` database roles or disable RLS to fix access errors.

Regular signed-in users can report and request routes. Assign `app_metadata.roles: ["reviewer"]` or `["admin"]` only through trusted Supabase administration/Admin API. A reviewer and admin are distinct permissions; assign both when needed. `user_metadata`, the ordinary `role: authenticated` claim and top-level custom roles do not grant moderation rights in Supabase mode.

## 2. Configure Mapbox

Create a dedicated Mapbox token with Search API access and put it in Render as `MAPBOX_ACCESS_TOKEN`. Use a server-compatible token: browser URL restrictions can reject server requests. Do not put it in source, examples, screenshots or the iOS bundle. Set account usage alerts in Mapbox.

The service provides:

- `POST /api/v1/commercial/mapbox/category`: nearby `coffee` (cafés) or `food_and_drink` results within a small viewport.
- `POST /api/v1/commercial/mapbox/suggest`: business-name autocomplete, restricted to POIs.
- `POST /api/v1/commercial/mapbox/retrieve`: selected business details, requesting optional `visit` metadata.

Use one fresh UUIDv4 per autocomplete interaction, pass it as `session_token` for suggestions and the selected retrieval, then start a new session. Category requests do not use session tokens. Debounce the client, cancel obsolete requests and avoid fetching on every animation frame. Authenticated requests are limited to 20/minute per user; account-wide provider throttling is handled as a temporary service error.

Results retain Mapbox attribution, metadata and operational status where provided. They are returned with `Cache-Control: private, no-store`. Do not persist them or their IDs in PostGIS, feedback, analytics or saved routes; permanent storage needs separate provider rights. They must not become evidence for OSM edits. Do not enable HTTP request/response debug logging that would record tokens or location queries.

An active business is not necessarily open at the planned arrival time. This integration returns `arrival_hours_status: unknown`; optional provider hours are preserved as metadata, not guessed or interpreted as a verified schedule. The existing curation endpoint still uses OSM/community hours. Mapbox discovery is not yet connected to SwiftUI or the route candidate pool. Search Box currently documents US/Canada/Europe coverage, so it does not fulfill worldwide commercial coverage by itself; OSM discovery remains separate.

Example category body (send with a Supabase user bearer token):

```json
{"category":"coffee","proximity":{"type":"Point","coordinates":[-87.625,41.885]},"bbox":[-87.63,41.88,-87.62,41.89],"limit":10,"language":"en"}
```

## 3. Create Render service

1. Connect `unfound-2/PausePath` to Render and create a **Blueprint** using the root `render.yaml`.
2. Review the proposed **Starter paid web service** before creating it. The pre-deploy migration step requires a supported paid plan. No additional Render database is requested.
3. Fill in secret settings:

| Setting | Value |
| --- | --- |
| `DATABASE_URL` | Supabase session-pooler URI with TLS |
| `MIGRATION_DATABASE_URL` | Same owner URI initially; must be session/direct, not transaction pooling |
| `AUTH_ISSUER`, `AUTH_JWKS_URL` | Project values from step 1 |
| `MAPBOX_ACCESS_TOKEN` | Server-side Mapbox Search token |
| `PEDESTRIAN_ROUTER_URL` | Your dedicated pedestrian OSRM service URL; leave blank until available |

The Blueprint sets `DB_SCHEMA=pausepath`, `DB_EXTENSIONS_SCHEMA=extensions`, pool size 5 and the Supabase audience/role source. Each API instance holds at most five DB connections; leave capacity for Supabase's own services before scaling replicas. Prepared statements are disabled for pooler compatibility. No schema configuration uses PostgreSQL startup `options`, which poolers may reject.

4. Deploy. Render builds `backend/Dockerfile`, runs `python scripts/migrate.py` before release, and starts Uvicorn on Render's assigned `PORT`. `/ready` verifies the app can access the migrated POI table.
5. Verify `/health`, `/ready` and `/docs` at your Render HTTPS URL. Confirm unauthenticated report requests return 401, then use a real Supabase user token for a Mapbox search. An empty result is valid and does not establish absence of facilities.

Without the pedestrian router, route curation intentionally returns 503; commercial search and reporting remain usable. Mapbox Search does not supply the pedestrian connectivity checks. The existing iOS MapKit routing remains unchanged.

Community challenge groups, invite codes, challenge definitions and opt-in aggregate progress are stored in the private API schema by `20261017170000_community_challenges.sql`. The Render pre-deploy migration step applies it before the updated API starts. On a separately managed deployment, run `python scripts/migrate.py` from `backend/` with the same `MIGRATION_DATABASE_URL` (or owner `DATABASE_URL`) and `DB_SCHEMA` settings before deploying the updated API. Members see random walker aliases and challenge totals only; clients must not send route geometry, location, Health information, or reflection text.

## Operations and existing databases

Run `python scripts/maintenance.py` daily in a scheduler with the same database/schema settings to refresh report confidence and prune rate buckets. Keep DB backups enabled and define report retention before launch. Migration credentials are not needed by the mobile client.

Migrations are ordered and checksummed. Existing local databases continue to use `DB_SCHEMA=public` and `DB_EXTENSIONS_SCHEMA=public`; the original migration has not been rewritten. Never switch an existing populated database to a new schema just by changing an environment variable: migrate its data deliberately first. The unused Google ID table is retained for compatibility; Google routes and credentials have been removed.

References: [Supabase PostGIS](https://supabase.com/docs/guides/database/extensions/postgis), [Supabase connections](https://supabase.com/docs/guides/database/connecting-to-postgres), [Supabase JWTs](https://supabase.com/docs/guides/auth/jwts), [Render Blueprint fields](https://render.com/docs/blueprint-spec), [Mapbox Search Box](https://docs.mapbox.com/api/search/search-box/).

The goal lifecycle increment adds `walking_challenges.archived_at` through the checked migration runner. Deploy the API before distributing the new iOS build. Goal creation accepts an optional UUID4 `request_id` for compatibility with older apps; new clients persist it across uncertain retries. New member-authenticated goal endpoints are `POST /api/v1/communities/{group}/challenges/{challenge}/edit` and `/archive` (`{"archived":true}` or false). Only the creator or community owner may edit/archive/restore. Archive retains totals and blocks progress writes until restored. The private schema and direct-client access restrictions remain unchanged.

Community polish: `GET /api/v1/communities` now supplies `summary_available`, `active_goal_count` and optional `next_walk`. `GET /api/v1/communities/{group}/members` permits existing members to read display names, owner/self labels and group-scoped member keys. Actual account IDs remain owner-only; management endpoints retain their owner checks. No schema migration is needed. Deploy these API changes before distributing the corresponding iOS features.
