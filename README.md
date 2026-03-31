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
# Production/staging also require SMTP settings for password reset email.
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
- This root compose stack is the official app runtime.
- Dev DB mapping in root compose is `55433:5432`.
- Dev SMTP/UI now uses Mailpit through the same compose stack:
  - SMTP inside Docker: `mailpit:1025`
  - SMTP from host-side API commands: `localhost:1025`
  - Mail UI: `http://localhost:8025`
- Optional Adminer in dev root compose: `docker compose --profile devtools up -d adminer`.
- Dev compose now injects `MIGRATIONS_DIR=/workspace/infra/migrations` through `docker-compose.override.yml` so the bind-mounted repo and migration runner stay aligned.
- The old standalone `infra/db` compose stack is not part of the app runtime and should remain stopped unless you intentionally need an isolated DB experiment.

## API Local (without Docker)

```powershell
cd apps\api
Copy-Item .env.example .env
# Set the super admin bootstrap values before first start:
# SUPER_ADMIN_EMAIL=superadmin@gov.lb
# SUPER_ADMIN_PASSWORD=ChangeThis!Gov2026
# SUPER_ADMIN_FULL_NAME=GIS Super Administrator
# apps/api/.env.example now defaults to the official compose-backed runtime DB on 55433.
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
- For host-side API commands outside Docker, keep `apps/api/.env` on:
  - `MAIL_TRANSPORT=mailpit`
  - `SMTP_HOST=localhost`
  - `SMTP_PORT=1025`
  - `SMTP_FROM_EMAIL=no-reply@gis.local`
- To verify the running API container is using the intended mail transport:
  - `docker compose exec api sh -lc "printenv | grep -E '^(MAIL_TRANSPORT|PASSWORD_RESET_REQUIRE_REAL_DELIVERY|SMTP_)' | sort"`
- To verify the active transport from logs:
  - `docker compose logs api --tail 50 | Select-String \"Password reset mail transport initialized\"`
  - `docker compose logs api --tail 50 | Select-String \"Password reset email accepted by transport\"`

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
- DB host port for the official runtime: `55433`

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
