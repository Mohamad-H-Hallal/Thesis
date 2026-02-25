# Operations Runbook (Windows + Docker)

## Production Deployment Topology
- `db`: Postgres/PostGIS (`postgis/postgis:16-3.4`), persistent volume.
- `migrate`: one-off migration job (`node dist/db/migrate.js`) against `infra/migrations`.
- `api`: Node/TypeScript API container, non-root (`node` user), healthchecked.
- `nginx`: reverse proxy (`nginxinc/nginx-unprivileged`) exposing port `80` and routing `/api` to API.

## Environment Files
- Production compose: root `.env` (copy from `.env.example` and replace secrets).
- API local-only example: `apps/api/.env.example`.
- DB local-only example: `infra/db/.env.example`.
- Environment templates:
  - `.env.dev.example`
  - `.env.staging.example`
  - `.env.prod.example`

## Required Runtime Variables
- DB: `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`
- API DB: `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`, `MIGRATIONS_DIR=/app/infra/migrations`
- Auth: `JWT_SECRET_CURRENT`, `JWT_REFRESH_SECRET_CURRENT` (+ rotation fields)
- Routing: `API_VERSION_PREFIX=/api/v1`, `ENABLE_LEGACY_API_PREFIX=false`
- Security: `CORS_ORIGIN`, `CORS_STRICT=true`, `RATE_LIMIT_*`, `AUDIT_LOG_ENABLED=true`
- Observability: `METRICS_ENABLED=true`, `METRICS_TOKEN=<required in production>`

## Ports
- Nginx entrypoint: `80 -> 8080` (container)
- API: internal only (`3000/tcp` on compose network)
- DB: internal only in production compose

## First-Time Setup (Production-targeted)
```powershell
cd D:\GIS_APP
Copy-Item .env.example .env
# Edit .env and replace all placeholder secrets before go-live

docker compose -f docker-compose.yml up -d --build
docker compose -f docker-compose.yml ps
```

Alternative explicit env file:
```powershell
docker compose --env-file .env.prod -f docker-compose.yml up -d --build
```

Health checks:
```powershell
Invoke-WebRequest http://localhost/health
Invoke-WebRequest http://localhost/api/v1
Invoke-WebRequest http://localhost/docs/openapi.yaml
```

## Development Stack (with override)
```powershell
cd D:\GIS_APP
Copy-Item .env.example .env
docker compose up -d --build
```
Notes:
- `docker compose` (without `-f`) loads `docker-compose.override.yml`.
- Dev override publishes DB on `5433`, API on `3000`, nginx on `8088`, optional Adminer profile `devtools`.

## Version Update / Rolling Forward
```powershell
cd D:\GIS_APP
git pull
docker compose -f docker-compose.yml pull
docker compose -f docker-compose.yml up -d --build
docker compose -f docker-compose.yml ps
```

## Backup and Restore
DB backup:
```powershell
cd D:\GIS_APP\infra\db\scripts
./backup.ps1 -EnvFile ..\.env -OutputDir ..\backups
```

DB restore:
```powershell
cd D:\GIS_APP\infra\db\scripts
./restore.ps1 -DumpFile ..\backups\gis_app_YYYYMMDD_HHMMSS.dump -EnvFile ..\.env
```

Persistent app data:
- Uploads volume: `gis_app_api_uploads`
- Exports volume: `gis_app_api_exports`

Volume backup example:
```powershell
docker run --rm -v gis_app_api_uploads:/data -v ${PWD}:/backup alpine sh -c "tar czf /backup/api_uploads.tgz -C /data ."
docker run --rm -v gis_app_api_exports:/data -v ${PWD}:/backup alpine sh -c "tar czf /backup/api_exports.tgz -C /data ."
```

## Log Inspection
```powershell
docker compose -f docker-compose.yml logs -f api
docker compose -f docker-compose.yml logs -f migrate
docker compose -f docker-compose.yml logs -f db
docker compose -f docker-compose.yml logs -f nginx
```

## Troubleshooting
1. API not healthy:
- Run `docker compose -f docker-compose.yml logs api`.
- Confirm migrations completed: `docker compose -f docker-compose.yml logs migrate`.

2. DB startup failures:
- Run `docker compose -f docker-compose.yml logs db`.
- Validate credentials in `.env` and volume permissions.

3. Nginx responds but API routes fail:
- Check `infra/nginx/nginx.conf` and `docker compose -f docker-compose.yml logs nginx`.

4. Metrics endpoint accessible without token:
- Verify `.env` has non-empty `METRICS_TOKEN` when `NODE_ENV=production` and `METRICS_ENABLED=true`.

## Smoke Test Script
PowerShell:
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\smoke-test.ps1 -SkipUp
```

Bash:
```bash
bash ./scripts/smoke-test.sh
```

Smoke test assertions:
- `/health`, `/api/v1`, `/docs/openapi.yaml` reachable.
- Public admin signup attempt blocked.
- Contributor signup/login works.
- Protected endpoint `/api/v1/auth/me` succeeds with bearer token.

## Monitoring Baseline
- `/metrics` is token-protected (401 without token in production config).
- Forward container logs to centralized logging (ELK/OpenSearch/Loki).
- Prometheus/Grafana integration later:
  - scrape `http://api:3000/metrics` with `Authorization: Bearer <METRICS_TOKEN>` or `x-metrics-token` header.
  - alert on restart spikes, `/ready` failures, 5xx rate, DB latency.

## Evidence References
- `docs/handover/evidence/docker-up.log`
- `docs/handover/evidence/smoke-test.log`
- `docs/handover/evidence/backend-openapi-check-phase11.log`
- `docs/handover/evidence/backend-security-tests-phase11.log`
- `docs/handover/evidence/metrics-protection-phase11.log`
