# PausePath implementation plan

## Product decisions

PausePath should be usable wherever a person lives or travels, with location search as a fallback to GPS. Do not geographically restrict onboarding. The release experience must distinguish an area with sufficient verified data from an area where it can only offer discovery. No promise of complete coverage or instant network results.

Native SwiftUI, MapKit, CoreLocation and optional HealthKit are supported by the inspected environment: Xcode 27.0, Swift 6.4, iOS 26.5 and 27.0 simulator runtimes, and an initially README-only GitHub repository. Use simulator defaults until the owner provides a signing team. Start at iOS 17 for the SwiftUI map and Observation APIs.

## Milestone 0 — delivered scaffold

Integrated live map and world-place search, optional location permission, facility filters, unconstrained pedestrian route preview, deterministic route assessment with synthetic candidate routes, Health reads and activity review, feedback persistence, explicit user adjustments, and unit tests. Live discovery and synthetic planning are visibly separate. No clinical thresholds or recovery inference.

Acceptance: compile for iOS Simulator, pass engine tests, launch in Simulator. Demonstration data must be clearly marked. Exact checks and remaining manual tests are in VALIDATION.md.

## Route generation and navigation increment — delivered

The Plan screen now replaces sample cards with real out-and-back route creation. Users choose a start by search or GPS; up to four candidate bearings are routed with independent outbound and return requests. Only candidates within ±25% of requested distance are offered. Disconnected or substantially displaced route endpoints are rejected. All paths and written instructions come from Apple walking directions.

A foreground navigation screen tracks GPS against the current leg, shows current instructions and remaining distance/time, optionally speaks directions, supports pause/resume, and detects arrival. Each leg has independent progress so overlapping outbound/return paths do not cause immediate completion. Stale or inaccurate fixes cannot advance progress. Off-route users can explicitly recalculate the remaining waypoints or choose a return to their original start. Revised routes disclose changed distance and unverified requirements.

Users must acknowledge unverified terrain, seating gaps and hours before starting. This does not modify their saved preferences or mark these routes as satisfying the full constraint engine. Navigation pauses in the background and is not a substitute for a field-tested, background-capable navigation release. Device/field validation remains required.

## Milestone 1 — facility and terrain data foundation

Evaluate a global pedestrian graph/POI provider and elevation source; supplement with municipal and operator feeds without making those feeds a condition of app availability. OpenStreetMap-derived data is a candidate to evaluate, not an integrated or guaranteed source. Compare licensing/attribution, redistribution, freshness, coverage, cost, quotas, offline rights and timezone/hour parsing before choosing a provider. Do not send Health records to mapping providers.

Add provider protocols and normalized records with source, source ID, last checked date, confidence, pedestrian access, seating type/capacity, public/customer-only access, wheelchair/stair/surface metadata where known, opening-hours specification, timezone and temporary closures. An unverified café is not a guaranteed rest seat. Validate that fountains supply drinking water and bathrooms are publicly accessible.

Implement a timezone-aware hours service that expands recurring local hours into absolute intervals for the planning horizon, including overnight hours, daylight-saving transitions, holiday overrides and exceptions. Preserve unknown and closed states separately. Evaluate at predicted arrival and expected stop duration; refresh when departure, speed, breaks or route changes. Do not silently treat unknown hours as open.

Acceptance: provider integration tests, attribution in UI, cached timestamps, explicit coverage/unknown states, documented multi-region sample coverage, and rate-limit/retry behavior. Cached data is labelled with age and never presented as live verification.

## Milestone 2 — real constrained route generation

Introduce an editable starting point and loop/out-and-back choice. Build candidates over the pedestrian graph, not straight-line geometry. Snap facilities to reachable route access points and include any access detours. Compute along-route segment lengths and grade from adequate elevation samples; handle bridges/stairs and uncertain elevation separately.

Filter candidate routes using desired distance with a clearly disclosed tolerance, user maximum grade and maximum distance between confirmed usable seats. Check the start-to-first-seat and final-seat-to-end gaps. Never claim that an arbitrary start/end contains seating. Required amenities must be reachable and open at ETA. Do not count a closed café or bathroom as a seating point merely because it is a POI.

Rank feasible routes by closeness to the user's chosen distance and goal, data confidence and detour burden. Fresh-air goals can favor green spaces; routine goals can favor repeatable familiar loops; exploration can favor variety. These are preferences, not health prescriptions. Show tradeoffs and explanations. If no candidate satisfies constraints, state that plainly and let the user explicitly change them; never silently loosen a seating limit.

Upgrade the current distance-based Plan routes to verified constrained routes only once these conditions are met. Do not label current live routes as verified matches.

Acceptance: reproducible real walking paths, facility access verification, arrival-hour recomputation, rejection of unknown required data, and tests for no-route, sparse seating, steep segments, disconnected paths, slow pace and closed stops.

## Milestone 3 — walking session and review

Extend the implemented start/pause/resume/end actions and foreground route progress with recording and durable session recovery. Ask separately before background location or workout writing. Persist session state with appropriate file protection; support interruption and permission revocation. Do not count a route preview as a completed activity.

Keep Health integration opt-in. Support missing/denied/partial data without mislabelling the user as having denied read permission. Distinguish estimated distance, recorded distance, elapsed versus moving time and missing heart rate. Avoid double-counting imported activities and local recordings by stable identifiers. The first implementation reads workouts only, up to 30 in 30 days; remove pagination limits before representing complete historical progress.

Combine a walk's reported manageability and facility availability with its recorded distance/duration/pace to offer transparent options. Examples: a reported unavailable seat can prompt the user to choose closer or different stops; a comfortable completed walk can offer a modest longer-distance option if the user wants it. Show supporting context, allow dismissal, and require explicit application. Never interpret heart rate, speed, consistency or distance as medical recovery readiness or a safe exertion ceiling. No clinical scores, clearance badges or automatic progression.

Acceptance: linked feedback and activity lineage, undo/dismiss controls, stale/missing sample handling, local export/delete controls, and tests proving health data never independently changes preferences.

## Milestone 4 — accessibility and release

Validate VoiceOver, Dynamic Type, contrast, one-handed use, metric/imperial units, localization, date/number formats and local timezones. Provide a textual route/stop alternative to the map. Test low connectivity, rural coverage, denied GPS, location changes and very large visible map areas. Include route revalidation when a stop closes while walking and clear messaging when no reliable alternative exists.

Add app icon, launch branding, complete privacy disclosures, provider attribution, privacy policy/support URLs, signing, CI and TestFlight. Verify HealthKit entitlements on a physical device and App Store privacy/required-reason declarations against the shipped code. No deployment or App Store submission is part of the scaffold.

## Remaining owner decisions

No answer is needed to run the simulator scaffold. Before provider integration/release: data-provider budget and hosting preference; loop versus out-and-back priority; supported languages/units; account/sync expectations; and the Apple Developer team/bundle ID. Worldwide usability and simulator defaults are already confirmed.
