# Two-account acceptance check

Install the latest `main` build on both phones, then sign in with different Apple accounts. The new backend is live. No Health access or location sharing is required for these tests. Use clearly named test content; do not use an existing goal you want to keep for deletion testing.

1. **Invite:** On phone A, create “PausePath test circle.” Use Invite to share its code/link. On B, join it. Both phones should show the same group and two members after refresh.
2. **Create and edit:** A opens Goals and creates “Test goal” with a target of three walks. It should appear once. Use its manage menu to change the name and target. After refresh, B should see the changes.
3. **Permissions:** B should not see edit/archive/delete controls on A's goal. B creates another test goal; B can manage that goal, and A can manage it as community owner.
4. **Archive and restore:** A archives the first goal. It disappears from active goals on both phones after refresh. Show archived goals reveals it with its saved totals. Restore it and confirm it returns. Delete only a test goal and confirm the cancellation/confirmation actions behave correctly.
5. **Ownership:** A renames the test group; its title should update immediately. Transfer ownership to B. Reopen the group on both phones: B should have owner settings; A should no longer be able to rename or delete the group. A may still manage goals A originally created.
6. **My Path:** With PausePath selected, pull to refresh; it must not open the Health permission flow. Change a History filter, then open Insights: its caption should describe all activity types for the selected source. Weekly goals and recap must remain clearly labelled as PausePath-only. Try larger text and light mode; controls should remain readable and scrollable.

If something fails, note the phone (A/B), action, visible error text and whether refreshing changes the result. Do not share tokens, Apple credentials or Health readings. Automated PostGIS tests cover these membership/ownership and retry contracts; this checklist verifies real Apple sessions and the device UI.
