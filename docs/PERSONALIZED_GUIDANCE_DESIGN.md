# Personalized route guidance and motivation

## Purpose and product boundaries

Help people choose routes, understand route demands, make progress toward goals they choose, and find motivation without pressure. These features should adapt to a person's stated preferences, support different abilities and fitness levels, and preserve meaningful control over data and participation.

Route ratings, weather context, goals, and challenges are planning and reflection aids. They do not diagnose, assess medical readiness, set a safe exertion limit, or replace a person's judgment or clinician's advice. A profile such as injury recovery or chronic pain is a preference preset supplied by the user, not a medical record or a diagnosis.

The current app has route previews, local Health reads, local goals, and optional backend break-stop curation. The opt-in WeatherKit route preview and optional in-app weather updates are implemented; weather, route and amenity data still have coverage limits. Reliable slope and surface coverage, end-of-day summaries, and challenges are not implemented. The app must label missing data and avoid implying verified accessibility or complete coverage.

## 1. Weather-aware route guidance

### User flow

1. The user selects a route and planned departure time.
2. PausePath checks whether a forecast is available for the route and estimated walking window.
3. The route preview presents relevant conditions, forecast age, and uncertainty.
4. The user can compare another route or time, take a practical precaution, or continue with the original plan.

### Screens and information

- **Route preview:** show relevant conditions across the estimated walk window, the time the forecast was updated, and an uncertainty label.
- **Why it may matter:** explain route-specific factors only when supported by available data. Example: “Forecasts suggest this walk may feel more demanding in the afternoon heat. Shade information is limited.”
- **Optional actions:** offer choices such as “Try an earlier time,” “Compare another route,” or “Bring water.” Mapped shade or water stops are incomplete data, not guarantees.
- **During a walk:** show an update only for a meaningful change and only when the user enables weather updates.

### Settings and privacy

- Let users turn weather guidance off and choose which alerts they receive.
- Explain that forecast requests use route location and planned time.
- Do not retain route-based weather requests as an activity history.

### Edge cases

- Mark forecasts stale, uncertain, or unavailable; never state an uncertain forecast as fact.
- Show a time range when conditions may change during the walk.
- Treat missing shade, water, or shelter data as unknown.
- If an alternate route lacks enough environmental data, explain the limitation rather than implying it is safer or more comfortable.

### Success measures

- Users understand forecast uncertainty and can find alternatives.
- Users report that weather context helped them make a choice.
- Monitor alert dismissals and opt-outs to identify noisy or unwanted guidance.

## 2. Clear route difficulty ratings

### User flow

1. The user sees a plain-language rating on the route preview.
2. “Why this rating?” opens the factor breakdown and available data gaps.
3. The user can change their planning preferences and compare routes.

### Screens and information

- Use **Easy**, **Moderate**, or **Challenging**. An optional score out of 100 may be shown, with lower values indicating fewer estimated route demands.
- Explain the factors separately: distance, estimated duration, elevation, surface, stairs, and rest-stop availability.
- Mark missing inputs, such as “Surface information is incomplete” or “Elevation estimate unavailable.”
- State that a rating is a planning aid, not a measure of the user's fitness or ability.
- Present tradeoffs in the route comparison, rather than hiding a demanding factor behind one combined score.

### Settings and privacy

- Let users choose which factors matter and whether to display the numeric score.
- Keep preferences on device unless the user explicitly opts into sync.
- Do not infer difficulty preferences from Health data.

### Edge cases

- Show “Limited route information” instead of false precision when important inputs are missing.
- Explain that ratings may not be comparable when route data coverage differs.
- Do not label a route Easy solely because its distance is short if relevant factors such as stairs or steepness are known to be demanding.

### Success measures

- Users can explain the factors contributing to a rating.
- Users find routes that fit their stated preferences.
- Measure factor-detail and route-comparison use, not selection of harder routes.

## 3. Personalized goals and progress reports

### User flow

1. The user chooses an editable planning profile: beginner fitness, injury recovery, senior-friendly activity, chronic pain considerations, general fitness, or event training.
2. PausePath asks which planning choices would help, such as shorter routes, fewer stairs, closer rest stops, or flexible timing.
3. The user chooses a goal, such as selected walking days, route count, time, or a personally chosen distance.
4. At the end of the day, PausePath offers an optional activity summary and progress report.

### Screens and information

- **Planning profile:** profiles are editable preference presets, not diagnoses or clinical recommendations.
- **Goal setup:** support distance, time, route count, or flexible goals. Make goals easy to change or pause.
- **Activity summary:** state what was recorded and show progress toward the user's own goal in supportive, factual language. Example: “You completed one walk today. Your goal is two walks this week.”
- **Data context:** distinguish PausePath walks from Apple Health workouts and identify incomplete or unavailable records.

### Settings and privacy

- Health access is optional and read-only. Before requesting permission, explain exactly which data is used and for what, such as recorded walks for summaries or heart rate as a displayed workout detail.
- Provide useful manual options when Health is off. Let users review permissions, clear imported activity, and delete saved summaries.
- Do not send Health data to the backend or use it to diagnose, infer readiness, or override medical advice.
- End-of-day summaries and notifications are opt-in, with controls for delivery time and notification frequency.
- Keep profile and goal preferences on device by default. If sync is introduced, explain retention and deletion before enabling it.

### Edge cases

- Avoid repeatedly prompting after permission is denied; keep goal features usable without Health access.
- If Health data is absent or incomplete, explain what the summary can and cannot include.
- Let users revise or pause goals without framing the change as failure.
- Do not interpret heart-rate values or encourage activity against a user's comfort or clinician's advice.
- Avoid double-counting a locally recorded walk and its HealthKit copy; use stable identifiers where available.

### Success measures

- Users understand and control Health data use.
- Users can set, change, pause, and meet their own goals.
- Users find summaries useful and supportive; monitor notification opt-outs and feedback.

## 4. Community challenges and tasks

### User flow

1. The user opens an optional Challenges screen.
2. They choose private or community participation and select or adjust a target.
3. Progress uses only activity the user chooses to count or share.
4. The user can pause, leave, or complete a challenge at any time.

### Screens and information

- Offer variety without escalation: “Walk with a friend,” “Try three routes,” or “Choose a distance for this week.”
- Allow distance, time, route count, or a non-distance task.
- Show personal progress and remaining time without ranking participants.
- Clearly state what is shared and who can see it before joining a community challenge.

### Settings and privacy

- Participation is off by default; offer private or named-community participation.
- Share only challenge progress. Do not share precise route history or Health data by default.
- Let users hide progress, leave a challenge, block or report participants, and control whether completed challenges appear on a profile.
- Avoid public leaderboards, pressure-based streaks, and automatic sharing.

### Edge cases

- Allow breaks and flexible completion windows.
- Keep missed or paused goals neutral; avoid guilt-based reminders.
- Offer participation without activity-data sharing.
- Provide moderation and a clear reporting path for community spaces.

### Success measures

- Users choose challenges at a level they set and can complete on their own terms.
- Users can pause or leave without penalty.
- Monitor unwanted-sharing reports and pressure-related feedback alongside participation.

## Recommended rollout

1. Add route-factor explanations and data-quality labels.
2. Add weather context once route/time forecasts and uncertainty can be represented reliably.
3. Extend local goals and Health features with optional summaries and explicit privacy controls.
4. Start with private challenges; add community participation after sharing and moderation controls are ready.

## Dependencies and release checks

- Route ratings need dependable elevation, surface, stairs, and rest-stop data with provenance and freshness. Missing inputs must remain visible.
- Weather guidance needs route-time forecasts, uncertainty/freshness metadata, and accessible alternatives when data is unavailable.
- Goal summaries need clear separation of locally recorded and imported activity, duplicate handling, and user-controlled retention/deletion.
- Community challenges need participation visibility controls, moderation/reporting, and explicit leave/pause behavior before launch.
- Validate VoiceOver, Dynamic Type, contrast, localization, units, reduced-motion preferences, and use without GPS or Health access.
- Keep route and stop recommendations within known data. Do not imply verified accessibility or complete facility coverage.
