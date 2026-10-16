# Connected iOS systems

The Swift app uses the live Render API at `https://pausepath-api.onrender.com` and Supabase Auth project `yrigwegtumlybprrhdgv`. Public configuration is in `PausePath/Services/PausePathAPI.swift`. No database password, service-role key, or Mapbox secret is bundled. Public browsing and route-curation requests need no token. Community reports use the signed-in user's JWT.

## Available in the app

- **Account:** email/password sign-in and account creation, confirmation-email instructions, device-only Keychain sessions, coordinated refresh, and local/server sign-out. All shared-stop exploration, route planning and Apple walking navigation are available signed out. Supabase email delivery and confirmation redirect settings must be configured for a public release; no email was sent during implementation.
- **Explore:** public viewport requests load OSM/community records and temporary Mapbox café results. Filters operate locally on category pins. Panning is debounced, superseded results are discarded, and foreground Explore refreshes each minute unless the user is reviewing a route or reporting a stop. Zoomed-out or date-line-spanning areas ask the user to zoom in. This is polling, not a Supabase Realtime subscription.
- **Reports:** submit observations on shared POIs, or suggest a new surveyed stop at map center. Retries retain the same request UUID; changing the report creates a new UUID. Suggestions require moderator review; Mapbox records cannot be reported into or copied into the OSM/community store. Existing moderation and OSM OAuth queue workflows remain operator tools.
- **Route review/navigation:** explicitly request breaks for an Apple walking route. The API receives geometry, departure and facility/interval preferences. Unknown hours are excluded by default, with a user toggle to include them. Suggested stops appear on the route map and in an ordered list; unfilled intervals remain explicit. Stop status is refreshed each minute. Temporary closures and inactive records disable stop guidance.
- **Walking to a break:** a selected stop opens new Apple walking directions from the available current location (or the original start for a preview), pausing the original walk. The user returns and resumes/recalculates their original walk. Breaks are optional separate detours, not silently spliced into the base route or its distance. Backend Mapbox connectors verify pedestrian access but Apple calculates the guidance path; hours predictions from the original curation must be rechecked when departure/path changes.
- **Health:** recorded activity, heart rate, walking speed and private reflections remain local. The curation API uses its standard walking speed, while the app can use local Health speed for its own time estimates. No medical readiness or exertion inference is made.

## Backend additions

`POST /api/v1/pois/search` accepts a bounded EPSG:4326 box (the existing `IngestRequest` schema), requires no account, returns `DiscoveryResponse`, and uses database rate limits (20/minute/peer for discovery, plus a shared 100/minute discovery ceiling). Every request reads current POI status, excluding inactive and temporarily closed stops. Responses are private/no-store, include attribution and explicit coverage warnings, and cap at 500 records.

OSM hydration is throttled to four upstream calls/minute/process, one concurrent call, with a bounded 256-entry 15-minute in-memory cache of successful boxes. On an upstream outage/busy budget the database still serves stored records with a warning. This baseline cache is deliberately separate from current community state. Multiple replicas multiply this upstream budget; introduce a shared ingestion worker/cache before scaling. No migration is needed.

Pedestrian connectors use the configured pedestrian OSRM URL when supplied, otherwise Mapbox's **walking** Directions profile with the server-side Mapbox token. Both outbound and return paths are checked, including endpoint snapping and connector distance limits. There is no driving-profile fallback. Provider token permissions/billing/coverage can still cause access checks to fail; unresolved stops remain unfilled.

Mapbox category metadata is displayed when present, and reported closed businesses are filtered out. Active business status is never treated as proof of being open at expected arrival. Search data is held in memory only and remains separate from persistent route-curation POIs. Opening-hours coverage is not guaranteed worldwide.

## Verification and release follow-up

- Simulator build and existing core tests, plus public discovery/area-bound/cache/failure/Mapbox walking-adapter tests, cover this integration.
- The discovery spatial query was executed successfully against live Supabase; the queried area currently had no stored records.
- A signed-in device walkthrough is still required: account confirmation, Explore hydration, report submission, expired-session refresh, and walking a detour. No real user credentials or fabricated community reports were used for testing.
- Keep the existing daily confidence-maintenance job operational. Public distribution also needs email configuration, account recovery/deletion flows, a published privacy policy and accurate App Store privacy disclosures. The privacy manifest now declares connected email, account ID, location and report-content use; Health data remains undeclared as collected because it is not uploaded.

Implementation references: [Supabase Auth REST contract](https://github.com/supabase/auth/blob/master/README.md), [Mapbox Search Box](https://docs.mapbox.com/api/search/search-box/), [Mapbox walking directions](https://docs.mapbox.com/api/navigation/directions/).

## Optional sign-in update

Read endpoints (POI discovery/details, route curation, Mapbox category/suggest/retrieve) are public. Reports, suggestions, admin ingestion, moderation and OSM edits still require their original authentication/roles. No Supabase table grants or RLS policies changed. Public clients cannot supply a user ID to bypass report authentication.

Public calls use HMAC-derived peer buckets (raw IPs are not stored), plus a database-backed shared budget of five times each per-peer action limit. The HMAC salt is process-local, so a restart resets peer identity while the global budget persists. Forwarding headers are not parsed by application code; keep Uvicorn's proxy trust restricted to the known ingress, never arbitrary clients. Shared NAT/proxy addresses may share limits. These are conservative launch limits, not a complete distributed abuse defense.

The iOS client sends no JWT for public reads, so an expired account cannot interrupt browsing. There is no signed-out Apple search substitution: everyone receives the same OSM/community and Mapbox sources. Apple Maps still supplies the basemap, address search and navigation.
