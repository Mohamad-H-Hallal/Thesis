# Monorepo Overview

This repository is a phase-0 scaffold for the Lebanese GIS Fruit Trees Data Collector (no AI pipeline).

![API Coverage Gate](https://img.shields.io/badge/API%20coverage%20gate-enforced-brightgreen)
![API Coverage Threshold](https://img.shields.io/badge/API%20line%20coverage-%E2%89%A530%25-blue)
![Mobile Coverage Gate](https://img.shields.io/badge/Mobile%20coverage%20gate-enforced-brightgreen)
![Mobile Coverage Threshold](https://img.shields.io/badge/Mobile%20line%20coverage-%E2%89%A519%25-blue)

## Repository Structure

```text
repo/
  apps/
    api/
    mobile/
  infra/
    db/
    migrations/
  docs/
  README.md
```

## Prerequisites

- Docker Desktop (with Linux containers)
- Node.js 22.x (LTS)
- Flutter 3.41+
- JDK 17 (required for Android Gradle builds)

## 1) Run Database (PostGIS)

```bash
cd infra/db
cp .env.example .env
docker compose up -d
```

Optional Adminer (DB UI):

```bash
docker compose --profile tools up -d adminer
```

- PostGIS: `localhost:5433`
- Adminer: `http://localhost:8080`

## Production-Targeted Docker Compose (Single Server)

```powershell
cd D:\GIS_APP
Copy-Item .env.example .env
# Replace placeholder secrets before deployment
docker compose -f docker-compose.yml up -d --build
docker compose -f docker-compose.yml ps
```

Environment template options:
- `.env.dev.example`
- `.env.staging.example`
- `.env.prod.example`

Smoke test:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\smoke-test.ps1 -SkipUp
```

Services:
- `nginx` exposed on `http://localhost` (port 80)
- `api` internal on `3000/tcp`
- `db` internal on `5432/tcp`

## 2) Run API (Express + Node.js)

```bash
cd apps/api
cp .env.example .env
npm install
npm run dev
```

Health checks:

- API: `http://localhost:3000/health`
- API ready: `http://localhost:3000/ready`
- API root: `http://localhost:3000/api/v1`
- OpenAPI: `http://localhost:3000/docs/openapi.yaml`

Quality commands:

```bash
npm run lint
npm run typecheck
npm run test
npm run test:perf
npm run release:gate
npm run migrate
npm run seed:staging
npm run staging:verify
```

## 3) Run Mobile (Flutter)

```bash
cd apps/mobile
flutter pub get
flutter run --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL=http://10.0.2.2:3000
```

Quality commands:

```bash
flutter analyze
flutter test --coverage
dart run tool/check_coverage.dart --min-line 19
dart format .
```

## CI Baseline

GitHub Actions workflow: `.github/workflows/monorepo-ci.yml`

- API job: migrate + lint + typecheck + test + performance tests + audit
- Mobile job: analyze + test + coverage threshold gate
- Staging readiness workflow: `.github/workflows/staging-readiness.yml` (manual + weekly)

## Security Defaults in Phase 0

- No real secrets committed
- API has helmet/cors/rate-limit wired
- `.env.example` files are provided for API and DB

## Phase 9 Ops Additions
- Audit logging for sensitive backend operations.
- Request ID, readiness, and metrics endpoints.
- DB backup/restore PowerShell scripts in `infra/db/scripts`.

## Phase 10 Quality Engineering Additions
- API e2e workflow test and performance baselines for BBOX and exports.
- Mobile sync performance baseline test.
- Release gate script: `apps/api npm run release:gate`.

## Phase 11 Deployment and Ops Additions
- Realistic staging seed profile: `apps/api npm run seed:staging`.
- Staging verification gate: `apps/api npm run staging:verify`.
- Phase 11 runbooks/checklists under `docs/phase-11`.

## Troubleshooting (Windows + Docker Desktop)

1. Docker database does not start:
- Ensure Docker Desktop is running and using Linux containers.
- Run `docker compose logs db` in `infra/db`.
- Confirm port `5433` is free.

2. API cannot connect to DB:
- Confirm `apps/api/.env` matches `infra/db/.env` credentials.
- Check DB health: `docker compose ps` and `docker compose logs db`.

3. Android emulator cannot call localhost API:
- Use `http://10.0.2.2:3000` instead of `http://localhost:3000`.

4. PowerShell copy command:
- Use `Copy-Item .env.example .env` if `cp` alias is unavailable.

5. Android/Gradle import fails due Java version:
- Ensure JDK 17 is active for Android builds.
- Verify with `cd apps/mobile/android && ./gradlew -v` (JVM must be 17.x).

## Handover Build & Run (Windows)

Requirements:
- Node.js 22.x
- Flutter stable
- Docker Desktop
- JDK 17 for Android

Commands:
```powershell
# 1) Database
cd infra\db
Copy-Item .env.example .env
docker compose up -d

# 2) Backend API
cd ..\..\apps\api
Copy-Item .env.example .env
npm ci
npm run migrate
npm run lint
npm run test:ci
npm run build
npm start

# 3) Mobile
cd ..\mobile
flutter pub get
flutter analyze
flutter test
flutter run -d chrome --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL=http://localhost:3000
```
