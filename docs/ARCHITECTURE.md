# Architecture and data contracts

The native iOS target compiles App, Core and Services directly. The separate Swift package compiles Core alone for fast, simulator-independent tests. The project has no external dependencies or secrets.

## Current flow

Explore → `PlaceDiscovery` → MapKit place search / walking directions → map annotations and route overlay.

Plan → `RoutePreferences` + searched/GPS start → `WalkingRouteBuilder` → outbound/return `MKDirections` → distance-filtered candidates → explicit unverified-data acknowledgment → `WalkingNavigator`.

Navigation → CoreLocation fixes → `WalkProgress` → per-leg geometry projection → current MapKit instruction, remaining distance/time, optional speech and arrival. Off-route recalculation preserves remaining endpoints; return-to-start intentionally replaces them. Original origin remains stable across reroutes. Navigation can use a foreground-started CLBackgroundActivitySession and location background mode. Pause/end invalidate that session and stop GPS; the display may lock normally. ActivityKit updates a separate WidgetKit extension. Lock Screen Pause targets the matching session; Resume returns to the app.

`DemoRoutes` is retained as development data. The full `RoutePlanner.assess` engine is not used to certify live MapKit routes because required grade/seating/hour data is absent.

My progress → explicit Health authorization → `HealthActivityStore` → recorded workout summaries. Feedback can reference an activity UUID. All three optional route adjustments require a button press and update preferences; heart rate is display-only.

Preferences, goal and feedback persist locally through UserDefaults. Recorded walks and their GPS traces live in `Application Support/PausePath/walk-history-v1.json` (`WalkHistoryStore`, readable after first unlock, migrated once from the old `pausepath.trackedWalks` UserDefaults key). An active walk is checkpointed every 30 seconds and on pause to `active-walk-v1.json`; if the app closes mid-walk, the next launch adds it to history as an unfinished walk. No medical state is modelled. Health samples are not persisted by PausePath. Linked activity IDs and user-entered notes remain in saved feedback until deletion. This is a prototype persistence mechanism; migrate sensitive feedback/session history to protected app storage before production. Reassess backup behavior and retention for the released product.

## Route assessment contract

- Distance is measured along the traversable path in meters, with ±25% desired-distance tolerance for this prototype.
- Grade is a maximum absolute slope percentage. Unknown slope fails a constrained terrain preference.
- Facilities need an along-route offset and explicit seating flag. Facility category alone does not imply seating.
- Hours use absolute start-inclusive/end-exclusive windows. `nil` is unknown; an empty array is known unavailable within the supplied planning horizon.
- ETA = departure + along-route meters / selected speed. Invalid speeds fall back to 1 m/s. Break duration, uncertainty and repeated stops are not modelled yet.
- Only facilities confirmed open at ETA satisfy required amenity and seating constraints. Every interval between route boundaries and usable seats is checked.
- Returned assessments explain rejection; they never change preferences or claim clinical suitability.

The sample dataset deliberately has unknown fountain hours so adding the drinking-fountain requirement demonstrates an unmet constraint. Sample route distances and geometric paths are illustrative, not measurements.

## Service boundaries to introduce next

`FacilityProvider`: fetch normalized records for a corridor/area with attribution and freshness.

`PedestrianRouteProvider`: produce routable candidate polylines and along-route facility access offsets.

`ElevationProvider`: grade observations with accuracy and unknown regions.

`OpeningHoursResolver`: recurring hours + place timezone + exceptions → absolute open intervals.

`SuggestionService`: user feedback + associated activity summaries → explainable, dismissible preference proposals. It must not produce medical readiness or exertion limits.

Keep raw provider DTOs outside Core. Add input validation before accepting external candidates, including nonfinite/negative distances, out-of-range offsets, duplicate visits, unreachable amenities and timezone errors. Current Core is fed trusted fixtures only.

## Concurrency and privacy

UI/service state is main-actor isolated. Map operations use generation tokens so older responses cannot replace a later query. The CLLocationManager is created on the main actor; its delegate conformance uses `@preconcurrency` for the legacy delegate API. Health queries resume async continuations and update UI on the main actor.

Permission requests occur only after relevant user action. Read authorization completion does not establish which Health data was shared, so empty data uses neutral wording. Navigation requests continuous GPS only after Start and can continue while locked when enabled. Pause/end stop updates. Tracked journeys stay on device, and no Health writing or analytics SDK is included. Location quality thresholds (35 m accuracy, 15 s age) and the 40 m off-route threshold are engineering heuristics, not health thresholds. Projection is bounded to a 150 m forward window to limit jumps at crossings; movement during a long interruption may require explicit rerouting. Remaining distance rescales geometric progress to Apple’s reported distance; it is an estimate, not a recorded workout.
