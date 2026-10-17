# Temporary weather provider

Open-Meteo replaces WeatherKit for now. No Apple weather capability, service key or new backend deployment is required. Rebuild the iOS app to receive this change.

Weather remains opt-in with new provider-specific preference keys. Up to three route locations are rounded to two decimal degrees before requesting seven days of hourly apparent temperature, precipitation probability and WMO weather codes. Planned departure is matched locally, not sent. Unix timestamps avoid timezone/DST ambiguity. Missing values are omitted, not converted to zero. During navigation, optional foreground checks compare the current forecast hour (model estimates, not observations).

An ephemeral URLSession and a maximum 24-entry memory cache retain forecasts for 15 minutes. Each request times out after 12 seconds. Cancellation prevents obsolete results from publishing, and failures do not block navigation. No forecast coordinates are persisted by PausePath. Open-Meteo can retain request logs up to 90 days; the opt-in copy discloses this.

Attribution is shown beside forecasts. The free API is for non-commercial use only and has request limits; commercial release needs an appropriate provider plan or a switch back to WeatherKit. Never embed a paid provider secret in the app. Documentation: https://open-meteo.com/en/docs and https://open-meteo.com/en/terms.

The prior WeatherKit design remains in PERSONALIZED_GUIDANCE_DESIGN.md as historical design context; this document describes the active implementation.

Validation: the actual Swift adapter decoded a live public Chicago forecast with 168 hours; assertions verified nearby-coordinate cache reuse, normalized probabilities, and hourly UTC spacing.
