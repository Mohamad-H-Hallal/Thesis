# Operations Runbook (Phase 11 Production)

## 1) Production Stack Overview
Primary deploy file: `compose.prod.yml`

Services:
- `db` (Postgres/PostGIS) with persistent volume `postgis_data`
- `migrate` one-off service running `node dist/db/migrate.js`
- `api` Node.js production build (no watch mode)
- `nginx` reverse proxy, TLS-ready config

Routing:
- `/api/*` -> API container
- `/docs/*` -> API docs
- `/` -> Flutter web build (if present at `apps/mobile/build/web`)

## 2) First-Time Setup (Windows)
1. Prepare env file:
```powershell
cd D:\GIS_APP
Copy-Item .env.prod.example .env
```
Set a non-conflicting public port for local verification if needed:
```powershell
# Example for local Windows host (avoid common 80/8080 conflicts)
(Get-Content .env) -replace '^NGINX_HTTP_PORT=.*', 'NGINX_HTTP_PORT=8088' | Set-Content .env
```
2. Replace placeholder secrets in `.env` OR use Docker secrets files from `secrets/README.md`.
3. Validate compose:
```powershell
docker compose -f compose.prod.yml config
```
4. Start stack:
```powershell
docker compose -f compose.prod.yml up -d --build
```
5. Verify status:
```powershell
docker compose -f compose.prod.yml ps
$port = (Get-Content .env | Where-Object { $_ -like 'NGINX_HTTP_PORT=*' }).Split('=')[1]
Invoke-WebRequest "http://localhost:$port/health"
Invoke-WebRequest "http://localhost:$port/api/v1"
Invoke-WebRequest "http://localhost:$port/docs/openapi.yaml"
```

## 3) Staging Setup
1. Copy staging template:
```powershell
Copy-Item .env.staging.example .env
```
2. Configure staging domain/CORS/secrets.
3. Deploy with same compose file:
```powershell
docker compose -f compose.prod.yml up -d --build
```

## 4) Environment Variables (Required)
Core:
- `NODE_ENV`, `HOST`, `PORT`, `TRUST_PROXY`, `ENFORCE_HTTPS`

Database:
- `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` (or `POSTGRES_PASSWORD_FILE`)
- `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`, `MIGRATIONS_DIR`

Auth:
- `JWT_SECRET`, `JWT_SECRET_CURRENT`, `JWT_REFRESH_SECRET`, `JWT_REFRESH_SECRET_CURRENT`
- rotation fields: `JWT_SECRET_PREVIOUS`, `JWT_REFRESH_SECRET_PREVIOUS`

API/security:
- `CORS_ORIGIN`, `CORS_STRICT`, `CORS_CREDENTIALS`
- `API_VERSION_PREFIX=/api/v1`, `ENABLE_LEGACY_API_PREFIX`
- `RATE_LIMIT_*`
- `AUDIT_LOG_ENABLED`

Observability:
- `METRICS_ENABLED`
- `METRICS_TOKEN` (or `METRICS_TOKEN_FILE`) required when metrics are enabled in production.

## 5) Migrations and DB Source of Truth
- Canonical migrations: `infra/migrations`
- Compose deploy flow runs `migrate` service before API starts.
- Tracker table: `schema_migrations`

## 6) Backup and Restore
Linux/macOS shell scripts:
- `scripts/backup.sh`
- `scripts/restore.sh`

Usage:
```bash
bash ./scripts/backup.sh
bash ./scripts/restore.sh ./backups/gis_app_YYYYMMDD_HHMMSS.dump
```

Windows PowerShell scripts remain available under `infra/db/scripts`.

Restore drill checklist: `docs/handover/10-restore-drill-checklist.md`

## 7) Logging and Monitoring
- API logs are structured JSON to stdout in production containers.
- Watch:
  - API `/health` and `/ready`
  - DB disk and memory
  - restart counts
  - export queue completion/failure rates
- Metrics endpoint `/metrics` is token-protected when enabled.

## 8) Port Conflict Resolution (5433)
Detected owner of `5433`:
- `gis_app_db` (`infra/db/docker-compose.yml`) binding `0.0.0.0:5433->5432`

Fix applied:
- `compose.prod.yml` keeps DB internal-only (no host DB port mapping)
- `docker-compose.override.yml` dev DB mapping moved from `5433` to the configurable `POSTGRES_HOST_PORT` default `54329`

Evidence:
- `docs/handover/evidence/port-5433-docker-ps.log`
- `docs/handover/evidence/port-5433-netstat.log`
- `docs/handover/evidence/port-5433-container-owner.log`
- `docs/handover/evidence/port-5433-pid-owner.log`

## 9) Smoke Test
PowerShell:
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\smoke-test.ps1 -ComposeFile compose.prod.yml
```

Bash:
```bash
COMPOSE_FILE=compose.prod.yml bash ./scripts/smoke-test.sh
```

Assertions:
- `/health`, `/api/v1`, `/docs/openapi.yaml` reachable
- admin self-registration blocked
- contributor registration/login succeeds
- protected endpoint requires token and works with valid token

## 10) Rollback
1. Checkout previous release tag.
2. Restart compose stack:
```powershell
git checkout <tag>
docker compose -f compose.prod.yml down
docker compose -f compose.prod.yml up -d --build
```
3. If required, restore DB backup then rerun smoke test.
