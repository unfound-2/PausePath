# Connected iOS systems

The Swift app uses the live Render API at `https://pausepath-api.onrender.com` and Supabase Auth project `yrigwegtumlybprrhdgv`. Public configuration is in `PausePath/Services/PausePathAPI.swift`. No database password, service-role key, or Mapbox secret is bundled. Public browsing and route-curation requests need no token. Community reports use the signed-in user's JWT.

## Available in the app

- **Account:** native Continue with Apple replaces email/password registration. Apple confirms the account on device; no PausePath email confirmation is needed. A fresh cryptographic nonce and state protect each exchange with Supabase. Supabase sessions stay in device-only Keychain and refresh independently of Apple credential-status checks. The app clears a session after explicit sign-out or when Supabase confirms it is invalid. Exploration and navigation remain available signed out.
- **Explore:** public viewport requests load OSM/community records and temporary Mapbox café results. Filters operate locally on category pins. Panning is debounced, superseded results are discarded, and foreground Explore refreshes each minute unless the user is reviewing a route or reporting a stop. Zoomed-out or date-line-spanning areas ask the user to zoom in. This is polling, not a Supabase Realtime subscription.
- **Reports:** submit observations on shared POIs, or suggest a new surveyed stop at map center. Retries retain the same request UUID; changing the report creates a new UUID. Suggestions require moderator review; Mapbox records cannot be reported into or copied into the OSM/community store. Existing moderation and OSM OAuth queue workflows remain operator tools.
- **Route review/navigation:** explicitly request breaks for an Apple walking route. The API receives geometry, departure and facility/interval preferences. Unknown hours are excluded by default, with a user toggle to include them. Suggested stops appear on the route map and in an ordered list; unfilled intervals remain explicit. Stop status is refreshed each minute. Temporary closures and inactive records disable stop guidance.
- **Walking to a break:** a selected stop opens new Apple walking directions from the available current location (or the original start for a preview), pausing the original walk. The user returns and resumes/recalculates their original walk. Breaks are optional separate detours, not silently spliced into the base route or its distance. Backend Mapbox connectors verify pedestrian access but Apple calculates the guidance path; hours predictions from the original curation must be rechecked when departure/path changes.
- **Health:** recorded activity, heart rate and walking speed remain local. The curation API uses its standard walking speed, while the app can use local Health speed for its own time estimates. No medical readiness or exertion inference is made.
- **Weather:** route previews and meaningful in-walk updates are enabled by default and can each be turned off in Account settings. Previews request hourly conditions at up to three approximate route points using Open-Meteo; walking updates send approximate current location about every 15 minutes while navigation is active and the app is open. PausePath does not store forecast requests. The app displays forecast freshness, partial coverage, uncertainty language and Open-Meteo attribution. No WeatherKit capability is required. See docs/WEATHER.md for caching and provider limits.

## Backend additions

`POST /api/v1/pois/search` accepts a bounded EPSG:4326 box (the existing `IngestRequest` schema), requires no account, returns `DiscoveryResponse`, and uses database rate limits (20/minute/peer for discovery, plus a shared 100/minute discovery ceiling). Every request reads current POI status, excluding inactive and temporarily closed stops. Responses are private/no-store, include attribution and explicit coverage warnings, and cap at 500 records.

OSM hydration is throttled to four upstream calls/minute/process, one concurrent call, with a bounded 256-entry 15-minute in-memory cache of successful boxes. On an upstream outage/busy budget the database still serves stored records with a warning. This baseline cache is deliberately separate from current community state. Multiple replicas multiply this upstream budget; introduce a shared ingestion worker/cache before scaling. No migration is needed.

Pedestrian connectors use the configured pedestrian OSRM URL when supplied, otherwise Mapbox's **walking** Directions profile with the server-side Mapbox token. Both outbound and return paths are checked, including endpoint snapping and connector distance limits. There is no driving-profile fallback. Provider token permissions/billing/coverage can still cause access checks to fail; unresolved stops remain unfilled.

Mapbox category metadata is displayed when present, and reported closed businesses are filtered out. Active business status is never treated as proof of being open at expected arrival. Search data is held in memory only and remains separate from persistent route-curation POIs. Opening-hours coverage is not guaranteed worldwide.

## Verification and release follow-up

- Simulator build and existing core tests, plus public discovery/area-bound/cache/failure/Mapbox walking-adapter tests, cover this integration.
- The discovery spatial query was executed successfully against live Supabase; the queried area currently had no stored records.
- A signed-in device walkthrough is still required: Apple sign-in, Explore hydration, report submission, expired-session refresh, and walking a detour. No real user credentials or fabricated community reports were used for testing.
- Keep the existing daily confidence-maintenance job operational. Public distribution also needs account recovery/deletion flows, a published privacy policy and accurate App Store privacy disclosures. The privacy manifest now declares connected email, account ID, location and report-content use; Health data remains undeclared as collected because it is not uploaded.

Implementation references: [Supabase Auth REST contract](https://github.com/supabase/auth/blob/master/README.md), [Mapbox Search Box](https://docs.mapbox.com/api/search/search-box/), [Mapbox walking directions](https://docs.mapbox.com/api/navigation/directions/).

## Optional sign-in update

Read endpoints (POI discovery/details, route curation, Mapbox category/suggest/retrieve) are public. Reports, suggestions, admin ingestion, moderation and OSM edits still require their original authentication/roles. No Supabase table grants or RLS policies changed. Public clients cannot supply a user ID to bypass report authentication.

Public calls use HMAC-derived peer buckets (raw IPs are not stored), plus a database-backed shared budget of five times each per-peer action limit. The HMAC salt is process-local, so a restart resets peer identity while the global budget persists. Forwarding headers are not parsed by application code; keep Uvicorn's proxy trust restricted to the known ingress, never arbitrary clients. Shared NAT/proxy addresses may share limits. These are conservative launch limits, not a complete distributed abuse defense.

The iOS client sends no JWT for public reads, so an expired account cannot interrupt browsing. There is no signed-out Apple search substitution: everyone receives the same OSM/community and Mapbox sources. Apple Maps still supplies the basemap, address search and navigation.

## Native Apple sign-in setup

Supabase Apple provider is enabled for `com.unfound2.PausePath`. The native flow uses Apple's identity token and the original nonce at `/auth/v1/token?grant_type=id_token`. No web OAuth secret is configured or needed for this native-only flow. See [Supabase native Apple guidance](https://supabase.com/docs/guides/auth/social-login/auth-apple).

The Xcode target includes the Sign in with Apple capability and entitlement. Select your development team and enable automatic signing when building a fresh checkout. Users must still approve Apple's system prompt. Existing email sessions remain supported; choosing Hide My Email may result in a separate account, so account history is not silently merged. Email confirmation settings for legacy email accounts remain enabled.

## Rest-aware navigation and saved areas — October 21, 2026

Explore route generation now measures start-to-bench, bench-to-bench and bench-to-finish gaps on actual walking legs. A bounded search can insert pedestrian detours through nearby benches and remeasure. Closed, reported-unavailable, private and customer-only benches do not count. Unknown hours/access are optional and explicitly labelled unverified. A failed preference remains visible; the search does not claim exhaustive feasibility or terrain verification.

Public POI detail/search responses include the latest community confirmation timestamp and latest report timestamp/type, without reporter identity. Simple OSM weekly hours are normalized using the facility's coordinate-derived IANA timezone; unsupported holiday/seasonal rules stay unknown. The client checks opening throughout a five-minute break at expected arrival using the user's walking-speed estimate. The next pause refreshes status every minute in the foreground, warns about unavailability, and offers walking-route alternatives. Selecting an alternative explicitly rebuilds remaining legs and remeasures rest gaps.

Recently explored public stop snapshots persist on-device: eight areas, seven days, 5 MB maximum, 2,500 facilities per area. Corrupt/oversized data is ignored. Files are excluded from backup and protected until first device unlock. Temporary Mapbox Search records remain memory-only. Saved stops are labelled with refresh time and may be stale; this is not offline map or offline directions support. Users can clear snapshots in Profile.

Navigation uses the location background mode and a foreground-started CLBackgroundActivitySession when enabled. Optional speech uses the audio background mode only for directions. Pause/End stop GPS, pedometer updates and speech; Resume opens/requires the foreground app. Session updates populate an ActivityKit Live Activity and Dynamic Island through the WidgetKit extension, with a session-specific Pause intent. A Home Screen widget opens Explore. A terminated process is not silently restored: orphaned activities end on next launch. No remote push token or extra Apple integration is required for local Live Activities; signed-device provisioning must include the extension target.

Physical-device checks remain necessary for lock/unlock, interruptions, GPS accuracy, speech, Live Activity controls and battery use. Build/test success does not prove those field behaviors.

## Community reliability repair — October 21, 2026

The live database lacked all four `walking_*` community tables. Applied the existing `20261017170000_community_challenges.sql` migration in the private `pausepath` schema and recorded its repository checksum. RLS stays enabled and `anon`/`authenticated` have no direct table access; the authenticated API enforces membership. A rollback-only live create/member/challenge/progress check succeeded without retaining test groups.

New clients include an account-scoped request UUID for create/join, retained in a saved draft until success. The server saves the result atomically with membership in the existing private receipt table. Retrying the same payload returns the same group; reusing a request UUID for another payload returns 409. Legacy clients without UUIDs remain supported. Invite codes are eight readable characters, with allocation-collision retries. Pasting a PausePath invite link or a formatted code is supported.

Community groups now appear before personal weekly suggestions. Joined users get a compact overview, group search, member counts, expandable member/invite details and shared-goal presets. Groups remain visible if optional goals or progress sync fail. Goal lists load with at most four concurrent reads, redundant group fetches are removed, and unchanged totals are not re-uploaded. A service outage no longer traps a valid signed-in user behind a disabled Create button. Session changes clear old group state immediately. Community boards contain only members who have shared a progress record; creating a goal does not implicitly opt its creator in.

Render uses the free-compatible migration-first startup command documented in `backend/DEPLOYMENT.md`. The stronger readiness check prevents a missing community schema from passing as a ready backend. Existing migration files remain unchanged.
