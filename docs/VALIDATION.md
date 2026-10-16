# Validation

## Automated checks

- Xcode 27: generic iOS Simulator build, unsigned; arm64 and x86_64. Passed.
- Swift package: 17 core tests (nine route-engine and eight navigation-progress tests) passed with zero failures.
- Navigation tests cover accurate/stale GPS, starting away from the route, off-route progress, overlapping out-and-back legs, nearby crossings, backtracking and empty geometry.
- Route cases cover the final seating gap, exact allowed gap, unknown hours, hours at arrival rather than departure, unknown grade, speed-dependent ETA, missing requested facilities, closing-time boundary, and explicit-only preference adjustment.
- Xcode emits an informational App Intents metadata warning because the app does not implement App Intents.

## Simulator smoke check

Installed and launched on the iPhone 18 Pro / iOS 27 simulator. A captured screen confirms that the integrated map, facility annotations, filters, results list and tab navigation render. Live results were present, with the partial-search-failure message visible; this is not evidence of complete facility coverage. The local screenshot is in `.build-logs/simulator.png` (ignored by Git).

## Manual checks before release

These are not implied by a successful build:

- Search multiple countries, rural areas, non-Latin place names, network failures and no-result areas.
- Check bench/bathroom/fountain/café false positives. Current keyword matches are deliberately labelled possible stops.
- GPS denial and later revocation; current-location success; manual-search fallback.
- Pan/zoom, search visible area, toggle filters, request pedestrian directions from map center; compare overlay and distance.
- Plan selection, rejection explanations, sample route sheet, unknown fountain hours, and changed departure/speed.
- Health authorization on a signed physical device; no data, partial sharing, recorded heart rate unavailable and refreshed workouts. Health speed is optional and never an exertion recommendation.
- Save/delete feedback, relaunch persistence, optional activity linkage, explicit preference changes and weekly progress.
- VoiceOver, largest Dynamic Type sizes, landscape and iPad, metric/imperial localization.

HealthKit end-to-end behavior and worldwide data completeness cannot be established in a simulator smoke test. Real distance-based walking routes and foreground guidance are implemented. Verified slope/seating/hour-constrained routes are not; no generated route is evidence of real-world accessibility or medical suitability.

## Navigation-specific release checks

- Actual outdoor walking: step timing, GPS drift, dense crossings, urban canyons, turnaround and final arrival. Unit/replay tests do not replace field testing.
- Pause/resume, app background/lock, permission revocation and stale GPS; confirm no progress is credited while paused and no guidance is claimed in the background.
- Recalculate after deviation, return early, return after multiple recalculations, failed network requests and cancel during a request. Verify original start stays fixed.
- Recheck generated-route geometry and distances in multiple countries. Four bounded candidates do not constitute exhaustive route search.
- Optional speech and VoiceOver interaction. Spoken directions require physical-device validation.

Apple API references: [walking directions](https://developer.apple.com/documentation/mapkit/mkdirections), [route steps](https://developer.apple.com/documentation/mapkit/mkroute/step).

## Live route integration check

A real Apple Maps request from the public Millennium Park test coordinate produced three distance-matching out-and-back walks: 1,222 m (E Madison St), 1,470 m (N Michigan Ave), and 1,480 m (S Columbus Dr), each with written walking steps. Replaying each returned polyline in 10 m subdivisions advanced both legs and reached arrival. This validates the service and progress integration for those responses, not worldwide coverage or field GPS performance.

To repeat (requires network access and macOS with Xcode):

```sh
mkdir -p .build-logs
xcrun swiftc -parse-as-library PausePath/Core/RoutePlanning.swift \
  PausePath/Core/NavigationProgress.swift PausePath/Services/WalkingRouteBuilder.swift \
  scripts/LiveRoutingCheck.swift -o .build-logs/live-routing-check
.build-logs/live-routing-check
```

This optional integration check depends on Apple Maps availability and is separate from deterministic unit tests.

## Navigation simulator walkthrough

On iPhone 18 Pro / iOS 27, searched Millennium Park in the Plan UI, generated two real candidate walks, opened the route review, and checked the unverified-requirements acknowledgment. With synthetic public-landmark GPS, Start showed a real walking instruction (“Take a right”), step distance, remaining distance/time and leg count. Pause and Resume changed state as expected. Moving the simulated location off route displayed the alert; explicit recalculation produced a revised route and distance. End navigation returned to the planner. Screenshot: `.build-logs/navigation.png` (local, ignored by Git).

This walkthrough used simulated coordinates, not the user's real location. It did not validate outdoor accuracy, speech audio, full walked arrival, background behavior or Health recording. Arrival was verified by unit tests and replay of live route geometry.

## Explore map redesign

Built for iOS Simulator and visually inspected on iPhone 18 Pro / iOS 27. The map fills the screen behind floating search, category chips and a compact bottom card. Each category has its own color and symbol. Toggling Bathrooms immediately removed its pins and changed the visible count from 50 to 34 without a search. Tapping a fountain selected the pin and opened its details; requesting a walk displayed the real route, distance, time and Navigate action. The separate results sheet provides a text alternative to map pins. Reduce Motion disables the custom selection/filter animation.

The area search loads all four categories so subsequent filter changes are local. Incomplete map-provider coverage remains explicit.

## Automatic Explore refresh — code only

Added a 650 ms debounce for user-driven map movement, small-movement filtering, stale-request cancellation, automatic refresh after location recentering, and retention of existing pins during loading. Programmatic route fitting does not trigger a new facility search. Pending refreshes stop when leaving Explore or opening the results/navigation view. Manual refresh remains available.

Per the user's request, this increment has not been built, tested, or launched in the simulator.

## Connected systems — October 15, 2026

The completed connected-client implementation builds for the arm64 iOS simulator; all 17 existing Swift core tests pass. Backend tests: 27 passed, 5 database integration tests skipped locally because no isolated test database was supplied. Added tests cover auth rejection, bounding-box validation, no-store responses, hydration caching without caching community state, provider outages, result truncation, and Mapbox pedestrian outbound/return profiles. The live Supabase discovery SELECT succeeds and returns no records for the sampled area. See CONNECTED_SYSTEMS.md for remaining signed-in device acceptance work.

## Optional sign-in

Simulator build passes. Backend: 30 tests passed, 5 isolated-database tests skipped. New checks verify public read OpenAPI contracts, protected report/suggestion/admin/moderation/OSM routes, spoofed-header independence, and both per-peer and global request ceilings. Existing personal Xcode and Info.plist changes were preserved.

## Native Apple sign-in — October 16, 2026

All 19 Swift core tests pass, including nonce uniqueness/format and state/expiry rejection. Simulator and automatically provisioned signed iPhone builds succeed. The signed app contains `com.apple.developer.applesignin = [Default]`. Supabase's saved Apple provider configuration is enabled for `com.unfound2.PausePath`, with no web OAuth secret. Device-only Keychain persistence, refresh identity retention, cancellation, and revocation handling were reviewed. A full Apple account sign-in and authenticated report on a physical device still require the user's Apple confirmation and have not been claimed as tested. Local screenshot: `.build/apple-provider.png`.

## Archive bundle identifier repair — October 16, 2026

A local Info.plist edit used `$(com.unfound2.PausePath)` and `$(PausePath)` as build-setting references. Both expanded to empty values in the 1:00 PM archive. Restored `$(PRODUCT_BUNDLE_IDENTIFIER)` and `$(PRODUCT_NAME)` while preserving the other local plist contents. A fresh Release device archive succeeded at `.build/PausePath-fixed.xcarchive`; both its application plist and archive metadata contain `com.unfound2.PausePath`. Xcode Organizer recognizes it as an iOS App Archive and enables Validate App and Distribute App. This verifies archive creation, not App Store validation or upload.
