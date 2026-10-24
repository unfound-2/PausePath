# Challenge verification and deployment

The client now keeps create/join forms open on failed submissions, always exposes
the create/join entry point, and does not show a dismiss button on the Community tab.
Personal challenges count completed walks in the current week, exclude earlier known
route identities from new-route goals, and retain a per-week award ledger across
refreshes. Community totals begin at the challenge creation date. Opting out removes
progress rows; the leaderboard lists only members with shared progress.

Local backend suite: 56 passed, 6 skipped on Windows. Skips require an isolated
PostgreSQL/PostGIS database. The backend GitHub Actions workflow supplies one and
now covers create, invite/join, membership enforcement, idempotent totals, ordering,
and opt-out deletion. The iOS workflow runs Swift core regression tests and an
unsigned simulator build; these cannot run in the local Windows environment.

Production check on October 18, 2026: the public OpenAPI document at
https://pausepath-api.onrender.com/openapi.json contains no community or challenge
endpoints. Client changes alone cannot enable these operations. Before release,
apply backend/migrations/20261017170000_community_challenges.sql through the existing
migration runner and deploy the updated backend to Render. The free service's
startup does not automatically apply migrations (see backend/RENDER_STATUS.md).
No production database or hosting settings were changed by this verification.

Device acceptance: sign in, create a community, join using another account, create
one task of each metric, finish a walk, verify totals and completion after reopening,
turn sharing off and check the other account's board. Also test an offline create
retry, weekly/monthly rollover, fractional-distance progress, and weather toggles.
Only retained local walk history is available to identify previously completed
routes; older records without route identities are not guessed from names.
