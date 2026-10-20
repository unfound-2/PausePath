# My Path

App-only implementation; no backend deployment or database changes.

- My Path replaces My progress throughout the app and notification copy.
- PausePath journeys and Apple Health workouts remain separate sources to avoid duplicate totals.
- 7/30/90-day summaries; comparisons use 7 or 30 complete calendar days versus the previous equal period.
- Journey detail includes a map, summary/share action, active time, pace, available steps/calories/heart rate, and a timeline.
- New PausePath walks save actual GPS sections. Pauses and weak GPS split the map. Older walks retain totals and show that no map is available.
- Recorded distance accumulates navigation progress across recalculations; it does not reset when the remaining route changes.
- Motion permission is requested when an active journey starts; steps are counted during active intervals when supported.
- Optional Health reads include up to 500 workouts and measurements from the past year, 90 days of daily steps/active calories, and workout routes on demand. Local journey detail can read shared Health values within its recorded start/end interval; these interval readings include pauses and are labeled accordingly.
- Missing Health readings are unavailable, not inferred from distance or replaced with zero. Body measurements have neutral trends and do not affect badges.
- 18 teal/lime badges reward completed local journeys, total distance, single-journey distance/time, distinct days and distance PRs. A first walk sets a baseline; ties and unfinished walks do not earn PRs. Earned badges persist on this device.
- The quote appears at the bottom of My Path, where it can be read without delaying startup.

## Verification

Core tests cover legacy decoding, route/step round trips, 18 unique badge criteria, genuine PRs, invalid measurements, and exact comparison-window boundaries. GitHub Actions runs the core suite and an unsigned iOS simulator build.

Physical-device follow-up: allow/deny Motion and individual Health categories; walk/pause/resume/recalculate/finish; confirm the resulting route, step count, badge feedback and history. Also inspect large Dynamic Type, dark mode and VoiceOver on device. These checks require an iPhone; they cannot be performed from this Windows workspace.
