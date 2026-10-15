# Render deployment — October 15, 2026

- Service: `pausepath-api` (`srv-db87v5avcj2c738i9iq0`)
- API: https://pausepath-api.onrender.com
- Dashboard: https://dashboard.render.com/web/srv-db87v5avcj2c738i9iq0
- Free instance in Ohio, Docker build rooted at `backend`, Dockerfile `Dockerfile`.
- Startup: `uvicorn app.main:app --host 0.0.0.0 --port 10000 --no-access-log`.
- Successful deploy: `dep-db8ltpff3r2c739aonj0`, application commit `2c6c24e`.
- `/ready` returned `{"status":"ready"}`, verifying the live Supabase connection.
- Database URL and Mapbox token were entered by the owner in Render environment settings. No credentials are stored in this repository.

The initial deployment failed because the Docker command's shell quoting was interpreted literally. Using the direct Uvicorn command fixed startup. The Blueprint now uses that command too; its paid Starter/pre-deploy configuration remains an optional alternative to this manually configured free service.

Mapbox authenticated search has not been exercised end-to-end with a real user token. The pedestrian router is still unconfigured, so route curation returns 503 until one is supplied. The iOS app is not yet connected to this API. Free Render instances sleep when idle. Future database migrations and daily maintenance must be run separately on this free plan.
