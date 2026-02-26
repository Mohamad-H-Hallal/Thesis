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
docker compose up -d --build
```

Notes:
- Dev DB mapping in root compose is `55433:5432` (to avoid conflict with `infra/db` stack on 5433).
- Optional Adminer in dev root compose: `docker compose --profile devtools up -d adminer`.

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
npm ci
npm run migrate
npm run dev
```

Health:
- `http://localhost:3000/health`
- `http://localhost:3000/ready`
- `http://localhost:3000/api/v1`
- `http://localhost:3000/docs/openapi.yaml`

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
flutter run -d emulator-5554 --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL=http://10.0.2.2:3000
```

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
- `docs/handover/09-android-emulator-guide.md`
- `docs/handover/10-restore-drill-checklist.md`
- `docs/handover/11-phase11-checklist.md`
