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
- Node.js 22.x (LTS)
- Flutter stable
- JDK 17 (Android Gradle)

## Production Deployment (Single Server Docker Compose)

```powershell
cd D:\GIS_APP
Copy-Item .env.prod.example .env
# Replace placeholders and/or use secrets files (see secrets/README.md)
# If 80 or 8080 is occupied on your host, set:
# NGINX_HTTP_PORT=8088

docker compose -f compose.prod.yml config
docker compose -f compose.prod.yml up -d --build
docker compose -f compose.prod.yml ps
```

Smoke test:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\smoke-test.ps1 -BaseUrl http://localhost:8088 -ComposeFile compose.prod.yml
```

## Development Docker Stack

```powershell
cd D:\GIS_APP
Copy-Item .env.dev.example .env
# Set super admin bootstrap before first stack start:
# SUPER_ADMIN_EMAIL=superadmin@gov.lb
# SUPER_ADMIN_PASSWORD=ChangeThis!Gov2026
# SUPER_ADMIN_FULL_NAME=GIS Super Administrator
docker compose up -d --build
```

Notes:
- Dev DB mapping in root compose is `55433:5432` (to avoid conflict with `infra/db` stack on 5433).
- Optional Adminer in dev root compose: `docker compose --profile devtools up -d adminer`.
- Dev compose now injects `MIGRATIONS_DIR=/workspace/infra/migrations` through `docker-compose.override.yml` so the bind-mounted repo and migration runner stay aligned.

## Infra DB Local Stack (Alternative)

```powershell
cd infra\db
Copy-Item .env.example .env
docker compose up -d
```

- PostGIS: `localhost:5433`
- Adminer: `http://localhost:8080`
- If `5433` is already in use on Windows, identify/stop the owner first:
```powershell
docker ps --filter "publish=5433"
netstat -ano | findstr :5433
```
- If you cannot free `5433`, change `infra/db/docker-compose.yml` port mapping before starting.

## API Local (without Docker)

```powershell
cd apps\api
Copy-Item .env.example .env
# Set the super admin bootstrap values before first start:
# SUPER_ADMIN_EMAIL=superadmin@gov.lb
# SUPER_ADMIN_PASSWORD=ChangeThis!Gov2026
# SUPER_ADMIN_FULL_NAME=GIS Super Administrator
# apps/api/.env.example targets the standalone local DB stack on localhost:5433 by default.
# If you want host-side API commands to use the root Docker compose DB instead, change DB_PORT to 55433 explicitly.
npm ci
npm run migrate
npm run dev
```

Health:
- `http://localhost:3000/health`
- `http://localhost:3000/ready`
- `http://localhost:3000/api/v1`
- `http://localhost:3000/docs/openapi.yaml`

Super admin bootstrap:
- Set `SUPER_ADMIN_EMAIL=superadmin@gov.lb`
- Set `SUPER_ADMIN_PASSWORD=ChangeThis!Gov2026`
- Set `SUPER_ADMIN_FULL_NAME=GIS Super Administrator`
- Configure them in the active `.env` file or Docker environment before first startup.

Staging seed safety:
- `npm run seed:staging` and `npm run phase11:staging` are destructive when `STAGING_SEED_RESET=true`.
- Use them only against an isolated staging/test database.
- Outside CI/test, set `ALLOW_DESTRUCTIVE_STAGING_RESET=true` explicitly if you intentionally want that reset.

Clean runtime reset:
- To wipe ordinary runtime/business data while keeping the migrated schema intact, use the API reset script with an explicit safety flag.
- Safest command for the compose-backed app runtime:
  - `docker compose exec api sh -lc "ALLOW_RUNTIME_RESET=true npm run reset:runtime"`
- This keeps extensions/types/schema/migration tracking, restores the singleton support-settings row, and re-creates the protected super admin from `SUPER_ADMIN_*`.

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
SUPER_ADMIN_EMAIL=superadmin@gov.lb
SUPER_ADMIN_PASSWORD=ChangeThis!Gov2026
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
