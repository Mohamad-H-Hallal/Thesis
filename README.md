# Monorepo Overview

This repository contains the Lebanese GIS Collector platform (Flutter mobile/web + Node API + PostGIS), production-targeted through Phase 11.

## Repository Structure

```text
repo/
  apps/
    api/
    mobile/
  infra/
    db/
    migrations/
    nginx/
  docs/
  scripts/
  compose.prod.yml
  docker-compose.yml
  docker-compose.override.yml
```

## Prerequisites

- Docker Desktop (Linux containers)
- Node.js 22.23.1 (LTS; pinned in `.node-version`)
- Flutter 3.41.2 stable / Dart 3.11.0
- JDK 17 (Android Gradle)

## Production Reference Configuration

`compose.prod.yml` plus `compose.observability.yml` is the hardened
single-server reference. It is not permission to deploy. Real DNS, certificate,
secret-manager, alert-delivery, WAF, backup/restore, and controlled outage
gates must pass in approved staging first.

```powershell
cd D:\GIS_APP
npm --prefix apps/api run production:config:check
npm --prefix apps/api run database:grants:check
npm --prefix apps/api run observability:config:check
```

For the certificate bootstrap, secret file inventory, staging exercises, and
rollback gates, follow
[`production-infrastructure-observability.md`](docs/security/production-infrastructure-observability.md).
Do not copy the example environment and run it unchanged: production
validation deliberately rejects its placeholder hostnames and identities.

## Development Docker Stack

```powershell
cd D:\GIS_APP
Copy-Item .env.dev.example .env
# Set super admin bootstrap before first stack start:
# SUPER_ADMIN_EMAIL=superadmin@example.com
# SUPER_ADMIN_PASSWORD=replace-with-strong-super-admin-password
# SUPER_ADMIN_FULL_NAME=GIS Super Administrator
docker compose up -d --build

# Full development stack with the Python AI server in real mode:
docker compose -f docker-compose.dev.yml up -d --build
```

Notes:
- This root compose stack is the official app runtime.
- Runtime env ownership:
  - real process/container environment wins first
  - host-side API startup then loads `apps/api/.env`
  - root `.env` is a fallback for missing host-side API values
  - root `.env` drives the Docker Compose app runtime
  - `apps/api/.env` drives host-side API commands like `npm run dev`
  - tracked `*.env.example` files stay as placeholders only
- AI service URLs in Compose:
  - API calls AI server at `http://ai-server:8000`
  - AI server callbacks API at `http://api:3000`
  - AI server connects to Postgres with the internal Docker URL
    `postgresql://...@db:5432/gis_app`
- Dev DB mapping in root compose defaults to `54329:5432` and can be overridden with `POSTGRES_HOST_PORT`.
- Dev SMTP/UI now uses Mailpit through the same compose stack:
  - SMTP inside Docker: `mailpit:1025`
  - SMTP from host-side API commands: `localhost:1025`
  - Mail UI: `http://localhost:8025`
- Optional Adminer in dev root compose: `docker compose --profile devtools up -d adminer`.
- Dev compose now injects `MIGRATIONS_DIR=/workspace/infra/migrations` through `docker-compose.override.yml` so the bind-mounted repo and migration runner stay aligned.
- Dev compose now runs the API with `npm run dev:docker`, which uses `nodemon --legacy-watch` for reliable source reloads on Windows bind mounts.
- Backend validation and route changes should now trigger an in-container restart during normal Docker development without requiring a manual container recreate.
- The old standalone `infra/db` compose stack is not part of the app runtime and should remain stopped unless you intentionally need an isolated DB experiment.

## Docker Data Persistence And How Not To Lose The Database

The development database is stored in a persistent Docker named volume mounted
at `/var/lib/postgresql/data`. The stable local app volume is:

```text
gis_app_postgis_data
```

The AI development compose file uses the same stable DB volume by default, so
switching between the normal app stack and the AI dev stack should not point the
app at a new empty database. Isolated smoke tests must use their own project and
volume names. If you start `smoke_ai_compose.ps1 -Start -IsolatedPorts`, that
stack uses an isolated DB volume such as `gis_ai_verify_postgis_data`; the app
can look empty there because it is intentionally not connected to
`gis_app_postgis_data`.

Safe stop:

```powershell
docker compose down
```

Dangerous commands:

```powershell
docker compose down -v
docker volume prune
docker system prune --volumes
```

`docker compose down` stops and removes containers/networks but keeps named
volumes. `docker compose down -v` deletes the named volumes for that Compose
project, including the Postgres data volume. `docker volume prune` and
`docker system prune --volumes` can delete database volumes that are not
currently attached to a running container.

Back up before risky operations:

```powershell
cd D:\GIS_APP
.\scripts\dev\backup_db.ps1
```

This writes a timestamped custom-format `pg_dump` file under `backups\db\`.

Restore requires an explicit data-loss confirmation:

```powershell
cd D:\GIS_APP
.\scripts\dev\restore_db.ps1 -BackupPath .\backups\db\gis_app-YYYYMMDD-HHMMSS.dump -ConfirmDataLoss
```

Do not run `npm run reset:runtime`, `ALLOW_RUNTIME_RESET=true npm run
reset:runtime`, staging seed reset, `docker compose down -v`, or any prune
command unless you have a verified backup and you intend to discard local data.

## API Local (without Docker)

```powershell
cd apps\api
Copy-Item .env.example .env
# Set the super admin bootstrap values before first start:
# SUPER_ADMIN_EMAIL=superadmin@example.com
# SUPER_ADMIN_PASSWORD=replace-with-strong-super-admin-password
# SUPER_ADMIN_FULL_NAME=GIS Super Administrator
# apps/api/.env.example now defaults to the official compose-backed runtime DB on 54329.
npm ci
npm run migrate
npm run dev
```

For local AI runs without Docker, set these in the active backend env
(`apps/api/.env` for `npm run dev`, or root `.env` as fallback):

```env
AI_SERVER_URL=http://127.0.0.1:8000
AI_CALLBACK_BASE_URL=http://127.0.0.1:3000
APP_PUBLIC_API_URL=http://127.0.0.1:3000
AI_CALLBACK_SECRET=dev-ai-callback-secret-change-me
AI_SERVER_TIMEOUT_MS=30000
```

For the Python AI server in host/manual mode, `DATABASE_URL` must point from
Windows to the Postgres host port, for example
`postgresql://<user>:<password>@127.0.0.1:54329/gis_app`. In Docker Compose,
the AI server runs inside the Compose network, so it uses the service name:
`postgresql://<user>:<password>@db:5432/gis_app`.

Then start the Python AI server from the AI repo:

```powershell
cd D:\AI-ML-pipeline-for-AI-Enhanced-Mobile-GIS
Copy-Item .env.example .env
.\scripts\start_ai_server.ps1
# or:
python -m uvicorn ai_server:app --host 127.0.0.1 --port 8000 --reload
```

## AI Server Integration

Flutter never calls or starts Python. The active flow is:

```text
Flutter app
  -> Node/Express API
  -> Python FastAPI AI server
  -> AI pipeline / GEE
  -> callback to Node/Express API
  -> Flutter run details refresh
```

### Do I need to start the Python AI server?

- For normal app browsing and non-AI features, Flutter plus the Node/Express
  backend may be enough.
- For AI readiness, Start AI Run, status callbacks, retrain checks, and AI Run
  Details refreshes, the Python FastAPI AI server must be running.
- In manual local mode, start it yourself:

  ```powershell
  cd D:\AI-ML-pipeline-for-AI-Enhanced-Mobile-GIS
  .\scripts\start_ai_server.ps1
  ```

- In Docker Compose mode, Compose starts the `ai-server` service automatically.
- In production, the AI server must run as a managed service or container.
- Flutter never starts the AI server and never calls it directly.

If readiness says `AI server URL is not configured`, the backend process did
not receive `AI_SERVER_URL`. Fix the active backend env file and restart the
API; the backend intentionally does not fake a queued run when dispatch is not
possible.

URL rules:
- Local manual: `AI_SERVER_URL=http://127.0.0.1:8000`,
  `AI_CALLBACK_BASE_URL=http://127.0.0.1:3000`
- Backend in Docker, AI server on Windows host:
  `AI_SERVER_URL=http://host.docker.internal:8000`
- Docker Compose: `AI_SERVER_URL=http://ai-server:8000`,
  `AI_CALLBACK_BASE_URL=http://api:3000`

Flutter's API base URL is separate from `AI_SERVER_URL`. `AI_SERVER_URL` is
backend-only. For an Android emulator, Flutter may need
`http://10.0.2.2:3000` as its backend URL; for a physical device, use the
computer's LAN IP such as `http://192.168.x.x:3000`. Do not use `10.0.2.2` for
`AI_SERVER_URL` unless the backend itself is running inside the emulator.

Development helpers:

```powershell
cd D:\GIS_APP
.\scripts\dev\start_ai_stack.ps1
.\scripts\dev\check_ai_stack.ps1
.\scripts\dev\smoke_ai_manual.ps1
```

`start_ai_stack.ps1` opens the host-side backend and Python AI server with the
manual-mode development URLs and `AI_DRY_RUN=false`. Run Flutter separately.
`check_ai_stack.ps1` checks backend and AI health. Authenticated readiness and
Start AI Run checks need a protected super-admin token and a project id because
the backend endpoints are protected.

Smoke-only auth/project values:

- `TEST_AUTH_TOKEN` is an optional JWT access token returned by the normal
  backend login endpoint (`POST /api/v1/auth/login`). For AI run creation it
  must belong to the protected super-admin. Its lifetime follows the backend
  JWT config (`JWT_EXPIRE`, 15 minutes by default). It is only for
  command-line smoke scripts; the Flutter app gets its token from normal login.
- `TEST_PROJECT_ID` is an optional project UUID from the backend `project`
  table/API. For AI smoke runs, the project must have AI enabled, a label field,
  approved/labeled ground-truth samples, valid AI settings/readiness, no active
  AI run, and a connected AI server. It is only for smoke scripts; the Flutter
  app uses the selected project id.

You do not need to set those manually when using auto mode:

```powershell
cd D:\GIS_APP
.\scripts\dev\smoke_ai_compose.ps1 -Start -StartRun -AutoAuth -AutoProject
```

`-AutoAuth` logs in through the real backend using `TEST_EMAIL`/`TEST_PASSWORD`
when set, otherwise `SUPER_ADMIN_EMAIL`/`SUPER_ADMIN_PASSWORD` from the active
env files. Tokens and passwords are never printed. `-AutoProject` lists projects
through the authenticated backend API and selects the first AI-ready project.
Set `AI_DRY_RUN=true` yourself only when you explicitly want a test-only smoke
run without GEE/database writes.

Docker Compose AI dev commands:

```powershell
cd D:\GIS_APP
docker compose -f docker-compose.dev.yml up --build
docker compose -f docker-compose.dev.yml logs -f api ai-server
docker compose -f docker-compose.dev.yml down
.\scripts\dev\smoke_ai_compose.ps1 -Start
```

Compose mode starts `api` and `ai-server`; do not manually run uvicorn in
Compose mode. The dev Compose file also starts the AI server with
`AI_DRY_RUN=false` and reads GEE settings from the AI pipeline repo `.env`
without committing those secrets to this repository. AI run output files persist
in the named `ai_outputs` volume.

Production should run the AI server as a managed service/container, for example
with an approved hardened overlay, systemd, Kubernetes, or the platform's
service manager. The mobile app never starts it.

More deployment detail lives in `docs/ai-deployment.md`.

API tests:

```powershell
cd D:\GIS_APP
docker compose up -d db
cd apps\api
npm ci
npm run test:ci
```

Notes:
- API tests use an isolated database by default:
  - host `localhost`
  - port `54329`
  - database `gis_app_test`
- Override the isolated test target with `TEST_DB_HOST`, `TEST_DB_PORT`, `TEST_DB_NAME`, `TEST_DB_USER`, `TEST_DB_PASSWORD`, and optional `TEST_DB_ADMIN_DB`.
- `npm run test:db:prepare` creates the test database if it is missing and applies migrations before the API test commands run.

Health:
- `http://localhost:3000/health`
- `http://localhost:3000/ready`
- `http://localhost:3000/api/v1`
- `http://localhost:3000/docs/` (interactive Swagger UI)
- `http://localhost:3000/docs/openapi.yaml`

OpenAPI testing:
- Open `http://localhost:3000/docs/`, select **Authorize**, and enter a valid JWT bearer token to test protected routes.
- The raw contract remains available at `/docs/openapi.yaml`; the executable, runtime-adjusted contract is at `/docs/openapi.json`.
- Validate the contract from the repo with `cd apps/api && npm run openapi:check`.

Super admin bootstrap:
- Set `SUPER_ADMIN_EMAIL` to a real deliverable mailbox for the protected super admin
- Set `SUPER_ADMIN_PASSWORD=replace-with-strong-super-admin-password`
- Set `SUPER_ADMIN_FULL_NAME=GIS Super Administrator`
- Configure them in the active `.env` file or Docker environment before first startup.

Password reset email:
- Forgot-password now uses a three-step flow:
  - email verification
  - OTP verification
  - new password submission
- Reset codes are delivered by real SMTP transport; the mobile UI never exposes a token.
- Two supported modes:
  - Local capture mode:
    - `MAIL_TRANSPORT=mailpit`
    - `PASSWORD_RESET_REQUIRE_REAL_DELIVERY=false`
    - reset emails are captured at `http://localhost:8025`
  - Real transactional mode:
    - `MAIL_TRANSPORT=smtp`
    - `PASSWORD_RESET_REQUIRE_REAL_DELIVERY=true`
    - `SMTP_HOST=...`
    - `SMTP_PORT=587` (or your provider's port)
    - `SMTP_SECURE=false` for STARTTLS on 587, or `true` for implicit TLS on 465
    - `SMTP_USER=...`
    - `SMTP_PASS=...`
    - `SMTP_FROM_EMAIL=...`
    - optional `SMTP_FROM_NAME=Lebanese GIS Collector`
- In real transactional mode, forgot-password only reports success when the provider accepts the recipient for delivery.
- In real transactional mode, forgot-password fails closed if:
  - `MAIL_TRANSPORT=mailpit`
  - `MAIL_TRANSPORT=smtp` but `SMTP_HOST=mailpit`
  - required `SMTP_*` values are missing
  - the SMTP provider rejects or fails the send attempt
- If you want host-side API commands outside Docker to send real SMTP mail too, mirror the same SMTP settings in `apps/api/.env`.
- If you want host-side API commands to stay on local capture only, keep `apps/api/.env` on:
  - `MAIL_TRANSPORT=mailpit`
  - `SMTP_HOST=localhost`
  - `SMTP_PORT=1025`
  - `SMTP_FROM_EMAIL=no-reply@gis.local`
- To verify the running API container is using the intended mail transport:
  - `docker compose exec api sh -lc "printenv | grep -E '^(MAIL_TRANSPORT|PASSWORD_RESET_REQUIRE_REAL_DELIVERY|SMTP_)' | sort"`
- To verify the active transport from logs:
  - `docker compose logs api --tail 50 | Select-String \"Password reset mail transport initialized\"`
  - `docker compose logs api --tail 50 | Select-String \"Password reset email accepted by transport\"`

Firebase mobile app config:
- Keep `apps/mobile/android/app/google-services.json` local only.
- Keep `apps/mobile/ios/Runner/GoogleService-Info.plist` local only.
- Both files are gitignored and should be replaced locally after any Firebase API key rotation.
- Current mobile Firebase API key allowlist should stay limited to:
  - `Firebase Management API`
  - `Cloud Logging API`
  - `Firebase Installations API`
  - `FCM Registration API`
- If you later add more Firebase mobile SDKs, update the API key allowlist manually:
  - Firebase Auth client SDK: add `Identity Toolkit API` and `Token Service API`
  - Firebase App Check: add `Firebase App Check API`
  - Cloud Firestore: add `Cloud Datastore API` and `Cloud Firestore API`
  - Cloud Storage: add `Cloud Storage for Firebase API`

Staging seed safety:
- `npm run seed:staging` and `npm run phase11:staging` are destructive when `STAGING_SEED_RESET=true`.
- Use them only against an isolated staging/test database.
- Outside CI/test, set `ALLOW_DESTRUCTIVE_STAGING_RESET=true` explicitly if you intentionally want that reset.

Clean runtime reset:
- To wipe ordinary runtime/business data while keeping the migrated schema intact, use the API reset script with an explicit safety flag.
- Safest command for the compose-backed app runtime:
  - `docker compose exec api sh -lc "ALLOW_RUNTIME_RESET=true npm run reset:runtime"`
- This keeps extensions/types/schema/migration tracking, restores the singleton support-settings row, and re-creates the protected super admin from `SUPER_ADMIN_*`.

Official Docker runtime commands:
- Start: `docker compose up -d db migrate api`
- Start with web reverse proxy too: `docker compose up -d db migrate api nginx`
- Stop: `docker compose down`
- Health: `Invoke-WebRequest http://localhost:3000/health`
- DB host port for the official runtime: `54329`
- API test DB on the same server: `gis_app_test`

## Mobile Local

```powershell
cd apps\mobile
flutter pub get
flutter run -d chrome --web-port 5050 --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL=http://localhost:3000
```

Web API prerequisite:
- Ensure API is reachable at `http://localhost:3000/health` before launching Chrome.

Android emulator:

```powershell
adb devices
flutter run -d emulator-5554 --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL=http://10.0.2.2:3000
```

Android notes:
- Use `10.0.2.2`, not `localhost`, for the local backend from the Android emulator.
- For a real Android device on the same network, use your computer's LAN IP instead:
  - `flutter run -d <device-id> --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL=http://<your-computer-lan-ip>:3000`
- `10.0.2.2` only works from the Android emulator.
- If you are testing over USB and prefer localhost-style routing, you can also run:
```powershell
adb reverse tcp:3000 tcp:3000
flutter run -d <device-id> --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL=http://127.0.0.1:3000
```
- If `API_BASE_URL` is omitted in `dev`, Android now defaults to `http://10.0.2.2:3000`; web keeps `http://localhost:3000`.
- If the emulator shows `offline`, restart ADB:
```powershell
adb kill-server
adb start-server
adb devices
```
- Debug Android builds allow local cleartext traffic for `10.0.2.2`.
- Admin and super-admin mobile provisioning is now available directly in-app:
  - `Projects` opens the project management flow
  - `Categories` is available from the admin drawer
  - project assignment management is available from each project card and details screen

## Release Verification (Single Command)

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\verify_all.ps1
```

This runs:
- Docker compose config validation (`compose.prod.yml`)
- Backend: `npm ci`, `lint`, `typecheck`, `test:ci`, `build`, `audit:prod`
- Mobile: `pub get`, `analyze`, `test --coverage`, `build web`, `build apk`

## Backup and Restore

Shell scripts:
- `scripts/backup.sh`
- `scripts/restore.sh`

Examples:

```bash
bash ./scripts/backup.sh
bash ./scripts/restore.sh ./backups/gis_app_YYYYMMDD_HHMMSS.dump
```

## Handover Documentation

- `docs/FINAL_HANDOVER_AND_DEPLOYMENT_GUIDE.md`
- `docs/handover/03-ops-runbook.md`
- `docs/handover/04-release-checklist.md`
- `docs/handover/05-user-guide.md`
- `docs/handover/06-admin-guide.md`
- `docs/handover/07-field-collector-guide.md`
- `docs/handover/08-reviewer-guide.md`
- `docs/handover/09-teammate-setup.md`
- `docs/handover/10-android-emulator-testing.md`
- `docs/handover/10-restore-drill-checklist.md`
- `docs/handover/11-phase11-checklist.md`

## Friend Handover Quick Start

```powershell
git clone https://github.com/Mohamad-H-Hallal/Thesis.git
cd Thesis
git checkout handover-ready
Copy-Item .env.dev.example .env
```

Set in `.env`:

```env
SUPER_ADMIN_EMAIL=superadmin@example.com
SUPER_ADMIN_PASSWORD=replace-with-strong-super-admin-password
SUPER_ADMIN_FULL_NAME=GIS Super Administrator
```

Then run:

```powershell
docker compose up -d db migrate api
Invoke-WebRequest http://localhost:3000/health

cd apps\mobile
flutter pub get
flutter emulators --launch Pixel_7_Pro_API_34
adb kill-server
adb start-server
adb devices
flutter run -d emulator-5554 --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL=http://10.0.2.2:3000
```
