# PausePath

An iOS app for walks with room to pause. Inspired by its creator's experience breaking a leg playing soccer, PausePath helps people express their own distance, terrain and rest-stop preferences. It does not determine medical recovery readiness or safe exertion limits; medical recovery decisions remain with healthcare providers.

This repository contains a **native iOS prototype** with real walking-route generation, an integrated Apple map, foreground navigation, and a roadmap for verified constrained planning. It is not yet a verified global accessibility or constrained-navigation service.

## Open and run

1. Open `PausePath.xcodeproj` in Xcode (developed with Xcode 27 / Swift 6.4).
2. Select the shared **PausePath** scheme and an iPhone simulator, then Run.
3. For a physical device, select your development team under Signing & Capabilities, choose your own bundle identifier if needed, and enable HealthKit for that identifier. No team is committed; the placeholder identifier is `com.unfound2.PausePath`.

Minimum deployment target: **iOS 17**. No third-party packages, API keys or backend are required for this scaffold. Map search/directions require an internet connection and regional Apple Maps service availability. The Swift core uses Swift 6; the app currently uses Swift 5 language mode.

```sh
swift test
xcodebuild -project PausePath.xcodeproj -scheme PausePath \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

## What works

- **Explore:** integrated MapKit map, search for any city/neighborhood/address, optional current location, filters for benches, bathrooms, drinking fountains and cafés, and a search of the visible map area. Results are possible stops, not verified facility records. Walking routes to selected places start at the map center and can be reviewed and navigated; terrain and rest-stop constraints are explicitly unverified.
- **Plan:** saved goal, distance, terrain, maximum seating gap, facility filters, departure time, manual speed and optional Health walking speed. Search a starting address or use GPS, then create real out-and-back walks using Apple walking directions for both legs. Candidates must fall within ±25% of the desired distance. The production generator currently targets distance only; other preferences are disclosed as unverified and require explicit acknowledgment before navigation.
- **Navigate:** full-screen map with route and current location, current walking instruction, textual direction list, optional spoken instructions, leg progress, remaining distance/time, pause/resume, off-route detection, explicit recalculation and return to the original start. Navigation stops on completion or exit. It pauses when the app enters the background; background/lock-screen guidance is not implemented.
- **Constraint engine:** the separate deterministic core still checks distance, grade, open-at-arrival facilities and seating gaps, but live MapKit data cannot yet supply verified inputs for all these constraints. Sample fixtures are retained in source for development, not displayed as real Plan routes.
- **My progress:** optional, read-only HealthKit authorization; up to 30 walking workouts from the past 30 days; distance, duration, pace and recorded average heart rate where available; a user-set weekly distance goal; locally saved feedback and optional linking to an activity. Users explicitly choose longer routes, flatter terrain or closer stops. Nothing changes automatically based on health or feedback.
- **Privacy:** no app backend, account, analytics or Health uploads. Apple handles map queries. Health results remain in memory; preferences, feedback and the weekly goal use app-local UserDefaults. Users can delete feedback and clear in-memory Health results. Health permission revocation is handled in system settings.

## Important boundaries

Worldwide discovery is a product requirement, not a claim of complete worldwide data. MapKit keyword searches can omit real benches or return unrelated businesses. Hours, seating and grade remain unknown in live results. A missing result does not mean no facilities exist. Searches are asynchronous; no instant or offline guarantee is made.

Live facility results are **not** connected to the constraint engine yet. The new route generator calculates traversable walking paths, but does not guarantee slope, seating gaps or open facilities. A selected walking goal is saved as user intent; goal-specific ranking is future work. Activity recording, background navigation, distinct circular loop generation, live hours ingestion, slope data, facility verification and automated suggestion ranking are future work. Health walking speed uses the latest available sample in 30 days and is an estimate only; timing excludes breaks.

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
