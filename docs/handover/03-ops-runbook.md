# Operations Runbook (Phase 11 Production)

> Phase 5 pre-deployment hardening supersedes the old direct-start and HTTP
> instructions below. The canonical security/operations procedure is
> [`production-infrastructure-observability.md`](../security/production-infrastructure-observability.md).
> Do not deploy from this historical Phase 11 runbook. Phase 7 will reconcile
> the final release runbook after all hardening phases are merged.

## 1) Production Stack Overview
Primary reference files: `compose.prod.yml` and `compose.observability.yml`

Services:
- `db` (Postgres/PostGIS) with persistent volume `postgis_data`
- `migrate` one-off service running with the database-owner credential
- `db-security` one-off restricted runtime-role grant service
- `valkey`, `clamav`, and a separate `workload-worker`
- `api` Node.js production build (no watch mode)
- `nginx` TLS reverse proxy and Certbot bootstrap/renewal services
- internal Prometheus, Alertmanager, blackbox exporter, Loki, and Alloy

Routing:
- `/api/*` -> API container
- `/docs`, `/ready`, and `/metrics` are denied at the public edge
- `/` -> Flutter web build (if present at `apps/mobile/build/web`)

## 2) Repository Validation

These commands do not deploy:

```powershell
npm --prefix apps/api run production:config:check
npm --prefix apps/api run database:grants:check
npm --prefix apps/api run observability:config:check
```

## 3) Staging Setup

Staging setup requires explicit approval and the external gates in the Phase 5
security design. Use a real non-production DNS name, unique staging secrets,
an approved alert receiver, encrypted off-server backup, and a documented
rollback. Never reuse production credentials.

## 4) Environment Variables (Required)
Core:
- `NODE_ENV`, `HOST`, `PORT`, `TRUST_PROXY`, `ENFORCE_HTTPS`

Database:
- `POSTGRES_DB`, `POSTGRES_USER`, `DB_RUNTIME_USER`
- database owner/runtime secret files selected by the host environment
- `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `MIGRATIONS_DIR`

Auth:
- mounted JWT access/refresh secret files
- rotation fields: `JWT_SECRET_PREVIOUS`, `JWT_REFRESH_SECRET_PREVIOUS`

API/security:
- `CORS_ORIGIN`, `CORS_STRICT`, `CORS_CREDENTIALS`
- `API_VERSION_PREFIX=/api/v1`, `ENABLE_LEGACY_API_PREFIX`
- `RATE_LIMIT_*`
- `AUDIT_LOG_ENABLED`

Observability:
- `METRICS_ENABLED`
- mounted metrics token required when metrics are enabled in production

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

# Approved disaster recovery only; prefer restoring to a new instance.
ALLOW_DESTRUCTIVE_RESTORE=I_UNDERSTAND \
EXPECTED_DATABASE=gis_app_prod \
bash ./scripts/restore.sh ./backups/gis_app_YYYYMMDD_HHMMSS.dump
```

Safe Windows drill:
```powershell
.\scripts\dev\restore_drill.ps1 `
  -ContainerName gis_app-db-1 `
  -Database gis_app `
  -User gis_user
```

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

## 9) Historical Smoke Test

The old smoke scripts expect public HTTP and public API docs, so they are not a
Phase 5 release gate. Phase 7 must replace them with HTTPS-only, hidden-ops
release probes before deployment.
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
