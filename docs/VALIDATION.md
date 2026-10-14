# Validation

## Automated checks

- Xcode 27: generic iOS Simulator build, unsigned; arm64 and x86_64. Passed.
- Swift package: nine route-engine tests passed with zero failures.
- Cases cover the final seating gap, exact allowed gap, unknown hours, hours at arrival rather than departure, unknown grade, speed-dependent ETA, missing requested facilities, closing-time boundary, and explicit-only preference adjustment.
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

HealthKit end-to-end behavior and worldwide data completeness cannot be established in a simulator smoke test. Real constrained routes are not implemented yet, so sample matches are not evidence of real-world route suitability.
