# Friends, group routes and saved areas

Implementation added October 22, 2026. Deploy the matching migration and API before distributing this iOS build. Release verification is recorded in docs/VALIDATION.md.

## Where to find things

Community now starts with Find friends and Inbox, followed by group creation, joining, and the group list. Profile also contains Friends (including username/privacy and blocked people), Community inbox, Notifications, Saved routes, and Downloaded areas. Group-walk creation and invitation actions stay in Community → group → Walks. Replacing a reported unavailable stop stays beside “Your next pause” during navigation. The preference for suggesting alternatives lives in downloaded-area/navigation settings.

A separate friend username uses 3–24 lowercase ASCII letters, numbers or underscores. Existing local/community display names are not uploaded into the directory automatically. Searchability is off by default and must be explicitly enabled. A person must also allow requests to appear in search. The inbox, local reminders, and existing group memberships work independently of opting into search.

## API and permissions

The new schema is defined in `backend/migrations/20261023010527_social_routes_and_notifications.sql`. Tables are API-only with RLS enabled and public, anon and authenticated table grants revoked. No frontend service-role credential or public Data API policy is introduced. Authenticated server endpoints check the current subject on every operation; privileged database connections remain server-only. Directory responses contain a public UUID and username, never email, token subject, precise location or Health data. Response models enforce the directory/inbox allowlist.

| Endpoint under `/api/v1/social` | Purpose |
| --- | --- |
| GET/POST `/profile` | Read/save your directory username and privacy settings |
| POST `/notification-preferences` | Change inbox categories without overwriting discovery preferences |
| GET `/search?q=prefix` | Opt-in literal username prefix search; min 3 characters, max 20 results |
| GET/POST `/friends` | List relationships / request a friendship |
| POST `/friends/{id}` | Recipient accepts/declines; sender cancels; either party removes |
| GET/POST `/blocks` | Your block list / block a public person UUID |
| POST `/blocks/{person}/remove` | Remove only your own block |
| POST `/walks/{walk}/invite` | Organizer/owner invites an accepted friend |
| GET `/invitations` | Pending non-cancelled future invitations addressed to you |
| POST `/invitations/{id}` | Accept and explicitly join the group/RSVP, or decline |
| GET `/inbox` | Up to 100 permission-scoped updates |
| POST `/inbox/read` | Mark only your own selected notifications read |
| GET `/reminders` | Your upcoming RSVPs in groups you still belong to |

Friendship uniqueness uses an unordered-pair index and transaction-scoped pair locks. Reciprocal requests remain pending until the recipient explicitly accepts. Block operations serialize against requests and invitations, remove the friendship, decline outstanding walk invitations and clear direct notifications. Unblocking does not restore those relationships. Turning requests or invitations off declines pending incoming items. A friend cannot read a group route until explicitly accepting the community invitation and joining. Walk organizers cannot invite arbitrary strangers. Declined invitations are not silently resent.

Blocking applies to direct friend discovery, requests and invitations. It does not hide existing shared group posts, goals or membership. The UI explains this scope. Location, recorded activity and Health data are never shared by friendship alone.

## Group routes

Group-walk creation accepts a validated optional `SharedRouteSnapshot` and `Point` meeting location through the typed `GroupWalkRequest` schema. A selected saved route has a map/stop preview and an explicit sharing toggle. A meeting pin can be searched, placed on a map, or set to the route start. Route snapshots are plans, not recordings. They contain at most 2,000 geometry points, 12 stops and 24 walking waypoints; extra fields such as Health measurements are rejected. Retrying the same submission does not duplicate a walk, and reusing its request ID for changed route/meeting details returns a conflict.

Joined members can refresh a shared route’s current stops and walking directions before opening the normal navigation preview. Replays preserve non-amenity turnarounds for out-and-back routes. Unavailable, restricted, closed-at-arrival, disconnected or missing stops cause an explicit failure instead of silently removing the planned break. Unknown opening/access data remains unknown. The regular rest-gap preview is still shown before starting.

## Inbox and reminders

The in-app inbox refreshes while PausePath is active, at most once per minute through the shared foreground refresh service. It includes friend requests, invitations, new/cancelled walks, goal creation/edit/archive/restore, and a shared goal reaching its target. Completion is announced once per goal, including after progress corrections. Group fan-out uses batched database operations; inbox storage is capped at 200 rows per account. Users can opt out of individual inbox categories. Existing notifications remain readable.

Optional local notifications require an explicit permission request in Notifications settings. Up to 30 RSVPed walks in the next 30 days are scheduled 15 minutes before starting. A foreground sync reconciles cancellations, leaving a group and RSVP changes; unchanged reminders are not recreated each minute. Signing out clears group reminders and the account’s in-memory inbox. Notification text is generic and omits route, meeting-point and Health details.

There is no APNs remote delivery in this increment. If another member cancels while the app is closed, an already scheduled local reminder can remain until the next sync. The UI tells people to open the app to check the latest plan. Daily recap notifications retain their existing separate controls.

## Saved routes and downloaded areas

Saved routes remain on the phone. The library adds favorites, named collections, search and deletion. Navigation previews have an explicit Save action. Existing saved records decode without the new fields; older records missing stop coordinates require rebuilding in Explore. Replaying a route rebuilds walking directions and refetches POIs; it never uses a saved polyline as live turn instructions. Temporary Mapbox business metadata/identifiers are not added to persistent stop records: generic category/independently calculated walking waypoints are kept, and business data is searched again before reuse.

Downloaded areas show timestamps, stop counts, storage, pin/unpin, refresh and removal. Users can search a place and save a 1, 2 or 4 km-wide area. The existing 5 MB/eight-area/2,500-stops-per-area budget remains; unpinned records are replaced first and expire after seven days. Pinned older records display a stale-data warning. New downloads that cannot fit fail explicitly. Partial provider collection is labelled incomplete. Temporary Mapbox records are excluded. These are offline stop details; offline street maps and offline directions are not included.

## Validation and release

- Generic simulator app and widget build passed.
- 53 Swift core tests passed.
- 99 backend tests passed with an isolated PostgreSQL database; 12 spatial/PostGIS cases remain skipped locally.
- Database-backed tests include three-account permissions, reciprocal requests, blocking, invitation consent, route retry payloads, cancellation/reminders, scoped read receipts, notification preferences, inbox limits, shared-goal completion deduplication, and revocation of inherited PUBLIC grants.
- Separate-connection tests verify simultaneous reciprocal requests, block/request races and opting out while a sender waits on a database lock. Fixtures require a database name ending in `_test`; they never use production.
- Simulator review checked Profile links, signed-out Friends, saved-route compatibility/map preview and downloaded-area management.
- Real Apple account/device checks, actual local notification delivery, live walking reroutes, and complete PostGIS CI remain release acceptance work. No production accounts, location records or memberships were fabricated for testing.

Before release: commit/push this increment, let CI run the full PostGIS suite, then deploy the matching API on Render. The existing `python scripts/start.py` applies the new checked-in migration before starting the server; `/ready` checks the new tables and route/completion columns. Then distribute the iOS build and verify the two-account workflow on devices. No new hosting secrets are needed for the inbox/local-reminder scope.
