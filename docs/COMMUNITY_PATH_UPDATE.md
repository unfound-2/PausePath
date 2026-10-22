# Community and My Path update

## Deployment
Apply `backend/migrations/20261022090000_community_features.sql` through the existing checksummed migration runner before starting the updated API. Deploy the backend before distributing the updated iOS app. No live migration or dashboard deployment was performed by the code change.

Group plans and posts are member-only. Group owners can rename, remove members, transfer ownership, and delete groups. Organizers/owners can cancel walks; task creators/owners can delete tasks; post authors/owners can delete posts. Leaving or removal clears that member's posts, reactions, RSVPs, and shared challenge totals, and cancels their planned group walks. Group routes are explicitly entered text plans, not uploaded recorded journeys or turn-by-turn routes. The feed loads the newest 50 posts and upcoming plans (up to 100).

New tables have RLS enabled and public/anon/authenticated grants revoked. API requests authenticate a Supabase identity and enforce membership/ownership through the server database role. Keep runtime role privileges aligned with the existing Community tables.

## Activity behavior
Walk ownership is captured for new recordings. Historical records without an owner remain local and are not automatically uploaded to any account. Sharing is opt-in and tied to the account that enabled it. Recorded history is no longer truncated at 500. Old records already dropped by earlier versions cannot be recovered.

Goals and recaps use all locally recorded PausePath activity, independently of source/history filters. Goals follow the device's calendar week. Health summaries stay separate; missing distance is not displayed as zero. Health reconnects on opening My Path or returning to the foreground after the user first connects it; clear session disables automatic reconnection. Health's existing import window remains one year/500 workouts.

Notes stay on-device. CSV exports contain the filtered history, excluding notes; GPX exports contain recorded coordinate segments. Health workouts can be hidden/restored in PausePath without modifying Apple Health. Deleting a recorded journey changes totals and PR calculations but preserves earned badges.

## Acceptance checks
On an iPhone/simulator: schedule and join a walk using two accounts; verify cancellation and member-only access; try shared goals, posts, cheers, transfer/remove/leave; retry a create request after connection loss; switch accounts with sharing on; record each activity type; verify goals/recaps at week boundaries; test missing Health distance, refresh, notes, CSV and GPX exports, delete and hide/restore. Build success does not replace these interactive checks.
