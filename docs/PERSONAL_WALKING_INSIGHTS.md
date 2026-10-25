# Personal walking insights and route suggestions

The existing on-device timeline joins completed or ended-early PausePath walking sessions with user-authorized Apple Health **walking workouts**. A Health workout overlapping a PausePath recording is omitted when at least 70% of the shorter recording overlaps and, if both have distance, their distances are within 35%. The PausePath record retains its route and optional feedback. Other workouts and day-wide step totals do not enter this trend. No new Health permission, server upload, remote analytics, or language model is used. HealthKit statistics still supply daily steps and energy elsewhere in My Path; workout duration comes from individual workouts so duplicate sessions can be removed.

## Weekly observations and comparisons

Insights uses the eight most recent **complete calendar weeks**, excluding the current week. Each observation stores its start/end dates, recorded walking-workout minutes per day, fitting validity, nonnegative quality weight, coverage state, and contributing record count. Session durations are allocated by temporal overlap when a session crosses a week boundary. A week with no eligible recorded session has a missing value and zero fitting weight, **not an observed zero**. Missing Health permission, an unimported workout, or incomplete coverage cannot establish how much a person actually walked. A valid week receives weight 1; record count is provenance, not a claim that the entire week was captured. Sample data uses a separate synthetic history path.

The fitted time coordinate is calendar weeks from the first displayed week, and the response is **recorded walking-workout minutes per day**. A fitted trend requires four valid observed weeks. The first-four and last-four calendar-week averages require all four weeks in each respective window to be observed; missing weeks are never replaced by other weeks. Percent change additionally requires a nonzero baseline. Total observed minutes sums only valid observations. The “minutes versus baseline” comparison is shown only when all eight weeks are observed: observed total minus the first-four-week average times 56 days. It compares with a **constant-baseline projection**, not an effect caused by PausePath. The chart distinguishes observed dots from the fitted line. The model returns derivatives at each observed knot; the UI reports the derivative at the latest observed week, in recorded minutes/day/week, not a medical recovery rate.

## Smoothing spline

For valid observations `(t_j, y_j, w_j)`, the model minimizes

`Σ_j w_j (y_j − f(t_j))² + λ ∫ (f''(t))² dt`

over natural cubic splines. It uses Reinsch's finite-dimensional representation: if `Q` is the second-difference operator for the irregular knot spacings, `R` is its spline roughness matrix, and `W` is diagonal observation weight, it solves

`(R + λ Qᵀ W⁻¹ Q)u = Qᵀy`, then `f_knots = y − λ W⁻¹Qu`.

Natural cubic interpolation through those smoothed knots provides a continuous second derivative and the chart samples. Pivoted Gaussian elimination is bounded to at most 16 observations. For six or more valid weeks, λ is selected deterministically by minimizing generalized cross-validation over 21 fixed logarithmic candidates from `10^-4` to `10^6`: `GCV = n · weighted residual / tr(I − S_λ)²`, where `tr(I − S_λ) = λ tr[(R + λ Qᵀ W⁻¹Q)⁻¹(QᵀW⁻¹Q)]`. Ties choose the first, smaller λ. For four or five observed weeks, λ is fixed at 1 week³ because GCV is unstable with so few points; the model exposes that limitation. Fewer than four valid weeks produce an insufficient-data status. Invalid dates, non-finite/negative values or weights, overlapping observation intervals, singular systems, and unsupported sizes produce a typed invalid result. Missing weeks retain their real time gaps. The dense candidate search is `O(21 n⁴)` time and `O(n²)` memory, acceptable for the eight-week UI window.

The [Desmos worked example](https://www.desmos.com/calculator/mfgk40ruru) is illustrative; it is not the production solver. The synthetic eight-week fixture `12, 13, 14, 15, 16, 17, 18, 19` min/day retains the linear reference summaries: slope 1 min/day/week, first four 13.5, last four 17.5, change about 29.6%, 868 observed minutes, and 112 minutes above a constant 13.5-minute baseline over 56 days. The tests check those values for this exactly linear series, while other spline results depend on λ and actual observations. “Sample walking insights” in Profile keeps synthetic results visibly separate from personal data.

## Route eligibility and cost

Route ranking first enforces the existing ±25% range around the explicit requested distance (`Dmax = 1.25 × request`, with the matching lower bound), required stop categories, chosen grade limit, and maximum rest gap. A known unavailable required stop, known excessive grade or rest gap, or unusable rest-gap data excludes a route. Unknown grade may remain provisional under existing product rules, but is never called flat. With no feasible route the ranker returns a no-match result and exclusion reasons.

The target distance `d*` is the median of up to 12 most recent completed, valid-distance walks when at least three such walks exist. Walks marked “Too demanding” are excluded. Otherwise the explicit requested distance is the target. Calculation never changes stored preferences. For each eligible route, lower cost is better:

`J = .35((d − d*)/d*)² + .15(g/G)² + .10 min(crossings/4, 1) + .15(1 − min(confirmed rest points/3, 1)) + .25u`

`G` is the user-selected grade cap (3% flat or 6% gentle); with “Any terrain,” 6% is only a scoring reference, not a hard cap. A missing grade, crossing count, or confirmed rest count receives the least favorable normalized value 1, not zero. `u` is the number of unknown fields divided by five: grade, surface, crossings, required-stop availability, and rest reliability. It is bounded to `[0,1]`; `1−u` is labeled **data completeness**, never safety confidence. Weights are finite, nonnegative, and sum to one. Fully known eligible routes sort ahead of provisional routes, then by ascending cost and stable route ID. The result includes per-term contributions, unknown details, eligibility text, and exclusion reasons for “Why this route?” in Explore.

Current Apple Maps route responses do not supply measured maximum grade, crossing count, or surface, so those fields stay unknown rather than being inferred. Stop hours and public access can also remain unknown; a mapped category alone is not a verified open/public facility. The recommended route is a planning suggestion under available data, not an exertion or injury-safety assessment. Users remain responsible for their own stated constraints and their care team's guidance.

## Known limits

Recorded workout minutes undercount unrecorded walking. Sparse records can make a fitted curve and derivative unstable even when four weeks exist; the small-sample method reports this and the UI does not fill gaps with zeros. The eight-week fixed windows deliberately leave comparisons unavailable if any required week is missing. Confirmed route features are rare until a provider supplies reliable elevation, crossing, surface, and facility access/hours data. Test the copy and chart with large text and with two real Health-connected devices before drawing product conclusions from the estimates.
