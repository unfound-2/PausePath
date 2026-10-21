# PausePath

An iOS app for walks with room to pause. Inspired by its creator's experience breaking a leg playing soccer, PausePath helps people express their own distance, terrain and rest-stop preferences. It does not determine medical recovery readiness or safe exertion limits; medical recovery decisions remain with healthcare providers.

This repository contains a **native iOS prototype** with real walking-route generation, an integrated Apple map, background-capable walking navigation, rest-aware planning and a Live Activity. It is not yet a verified global accessibility or constrained-navigation service.

## Open and run

1. Open `PausePath.xcodeproj` in Xcode (developed with Xcode 27 / Swift 6.4).
2. Select the shared **PausePath** scheme and an iPhone simulator, then Run.
3. For a physical device, select your development team under Signing & Capabilities, choose your own bundle identifier if needed, and enable HealthKit for that identifier. No team is committed; the placeholder identifier is `com.unfound2.PausePath`.

Minimum deployment target: **iOS 17**. No third-party packages, API keys or backend are required for this scaffold. Opt-in weather uses Open-Meteo without an Apple WeatherKit entitlement. The free endpoint is for non-commercial use; see docs/WEATHER.md. Map search/directions require an internet connection and regional Apple Maps service availability. The Swift core uses Swift 6; the app currently uses Swift 5 language mode.

```sh
swift test
xcodebuild -project PausePath.xcodeproj -scheme PausePath \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

## What works

- **Explore:** full-screen interactive MapKit map, floating search and filter chips, distinct color-and-symbol facility pins, tap-to-select stop cards, and a separate results sheet. Filters immediately show/hide cached category results without network reloads. Panning or zooming automatically refreshes nearby stops after a 650 ms pause, preserving existing pins while loading; route previews are not interrupted. Includes search for any city/neighborhood/address, optional current location, filters for benches, bathrooms, drinking fountains and cafés, and a search of the visible map area. Results are possible stops, not verified facility records. Walking routes to selected places start at the map center and can be reviewed and navigated; terrain and rest-stop constraints are explicitly unverified.
- **Plan:** saved goal, distance, terrain, maximum seating gap, facility filters, departure time, manual speed and optional Health walking speed. Search a starting address or use GPS, then create real out-and-back walks using Apple walking directions for both legs. Candidates must fall within ±25% of the desired distance. The production generator currently targets distance only; other preferences are disclosed as unverified and require explicit acknowledgment before navigation.
- **Navigate:** full-screen map with route and current location, current walking instruction, textual direction list, optional spoken instructions, leg progress, remaining distance/time, pause/resume, off-route detection, explicit recalculation and return to the original start. Explicitly started sessions can continue under the Lock Screen with optional spoken instructions. Pause/End stop location updates. A Live Activity shows guidance and the next pause, offers Pause, and opens the app to Resume. A Home Screen widget opens Explore.
- **Weather:** opt-in hourly forecasts for up to three points along the selected route, matched to the planned walk window. Previews show feels-like temperature, precipitation chance, forecast freshness/coverage, uncertainty, and Open-Meteo attribution. Optional meaningful-change updates appear only during enabled, active, foreground navigation. Weather requests are not saved by PausePath; route shade and water-stop information remain incomplete.
- **Constraint engine:** the separate deterministic core still checks distance, grade, open-at-arrival facilities and seating gaps, but live MapKit data cannot yet supply verified inputs for all these constraints. Sample fixtures are retained in source for development, not displayed as real Plan routes.
- **My progress:** optional, read-only HealthKit authorization; up to 30 walking workouts from the past 30 days; distance, duration, pace and recorded average heart rate where available; a user-set weekly distance goal; locally saved feedback and optional linking to an activity. Users explicitly choose longer routes, flatter terrain or closer stops. Nothing changes automatically based on health or feedback.
- **Privacy:** no app backend, account, analytics or Health uploads. Apple handles map queries. When weather guidance is enabled, Open-Meteo receives up to three approximate route points; optional in-walk checks send approximate current location about every 15 minutes while navigation is active and the app is open. PausePath does not save weather requests. Health results remain in memory; preferences, feedback and the weekly goal use app-local UserDefaults. Users can delete feedback and clear in-memory Health results. Health permission revocation is handled in system settings.

## Important boundaries

Worldwide discovery is a product requirement, not a claim of complete worldwide data. MapKit keyword searches can omit real benches or return unrelated businesses. Hours, seating and grade remain unknown in live results. A missing result does not mean no facilities exist. Searches are asynchronous; no instant or offline guarantee is made.

Explore planning now routes through mapped benches to reduce measured seating gaps, using actual pedestrian directions and expected-arrival hours. The search is bounded, not exhaustive: unmet gaps and unknown access/hours remain explicit, and users decide whether to use such a route. Community confirmation dates and the latest report come from the API. Public stop snapshots persist locally for up to seven days; offline maps and new offline directions are not included. Slope data, distinct circular loops and automated goal-specific ranking remain future work. Health walking speed uses the latest available sample in 30 days and is an estimate only; timing excludes breaks.

See [implementation plan](docs/IMPLEMENTATION_PLAN.md), [architecture](docs/ARCHITECTURE.md) and [validation checklist](docs/VALIDATION.md).

## Project layout

- `PausePath/App`: SwiftUI tabs, sample fixtures and app entry point.
- `PausePath/Core`: Foundation-only route and feedback domain, shared with the Swift package tests.
- `PausePath/Services`: MapKit/CoreLocation discovery and HealthKit reads.
- `PausePath/Resources`: permission descriptions, HealthKit entitlement and privacy manifest.
- `Tests/PausePathCoreTests`: route-constraint boundary tests.
- `scripts/LiveRoutingCheck.swift`: optional network integration check using a public landmark and replayed route geometry.
- `scripts/generate_project.py`: dependency-free Xcode project generator; run after adding Swift source files. The generated project is committed and ready to open.

Apple references: [MapKit for SwiftUI](https://developer.apple.com/documentation/mapkit/mapkit-for-swiftui), [HealthKit authorization](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data).

## Micro-amenity backend

The separate [backend service](backend/README.md) provides PostGIS storage, OSM ingestion, break curation, authenticated community reports and an OSM review queue. See its [API schema](backend/openapi.json) and [validation record](backend/VALIDATION.md). The iOS app is not yet connected to this service; the selected deployment is Supabase PostGIS/Auth, Render and Mapbox Search. See the [setup instructions](backend/DEPLOYMENT.md).
