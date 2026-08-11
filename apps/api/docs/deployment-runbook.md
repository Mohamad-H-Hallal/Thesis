# Deployment Runbook

> This API-only runbook is historical. For the current pre-deployment security
> boundary, TLS/bootstrap sequence, secret mounts, database role split,
> monitoring, and external gates, use
> `docs/security/production-infrastructure-observability.md` from the repository
> root. Do not deploy from this file alone.

## Scope
This runbook covers production deployment and operations for the GIS API.

## Prerequisites
- Node.js 22.23.1 LTS
- PostgreSQL 15+ with PostGIS extension
- Reverse proxy (Nginx or equivalent)
- TLS certificates
- Process manager (systemd, PM2, or container orchestrator)

## Environment Matrix
| Variable | Dev | Staging | Production | Notes |
|---|---|---|---|---|
| NODE_ENV | development | production | production | Production uses hardened behavior |
| PORT | 3000 | 3000 | 3000 | Internal port only |
| HOST | localhost | 0.0.0.0 | 0.0.0.0 | Bind appropriately |
| TRUST_PROXY | false | true | true | Required behind reverse proxy |
| ENFORCE_HTTPS | false | true | true | Reject plain HTTP in production |
| DB_HOST | local DB | staging DB | HA DB endpoint | Required |
| DB_PORT | 5432 | 5432 | 5432 | Required |
| DB_NAME | gis_app | gis_app_stg | gis_app_prod | Required |
| DB_USER | postgres | service user | service user | Least privilege |
| DB_PASSWORD | local secret | secret manager | secret manager | Never commit |
| JWT_SECRET | local only | strong secret | strong secret | Minimum 32 chars |
| JWT_SECRET_CURRENT | optional | current secret | current secret | Signing secret |
| JWT_SECRET_PREVIOUS | optional | previous secret(s) | previous secret(s) | Graceful rotation |
| JWT_EXPIRE | 15m | 15m | 15m | Production maximum is 1 hour |
| JWT_ISSUER | terraleb-api | deployment identifier | deployment identifier | Verified on every JWT |
| JWT_AUDIENCE | terraleb-mobile | client identifier | client identifier | Verified on every JWT |
| JWT_REFRESH_SECRET | local only | strong secret | strong secret | Minimum 32 chars |
| JWT_REFRESH_SECRET_CURRENT | optional | current refresh secret | current refresh secret | Signing secret |
| JWT_REFRESH_SECRET_PREVIOUS | optional | previous refresh secret(s) | previous refresh secret(s) | Graceful rotation |
| JWT_REFRESH_EXPIRE | 30d | 30d | 30d | Production maximum is 30 days; tokens are single-use |
| CORS_ORIGIN | local web URLs | staging frontend URLs | production frontend URLs | Comma-separated |
| CORS_STRICT | false/true | true | true | Require explicit allow-list |
| RATE_LIMIT_MAX_REQUESTS | 100 | 200 | tune by traffic | Anti-abuse |
| RATE_LIMIT_AUTH_MAX_REQUESTS | 20 | 20 | tune by threat model | Brute-force protection |
| RATE_LIMIT_EXPORT_MAX_REQUESTS | 40 | 40 | tune by workload | Export abuse protection |
| OFFLINE_SYNC_RATE_LIMIT_WINDOW_MS | 60000 | 60000 | tune by traffic | Offline sync limiter window |
| OFFLINE_SYNC_RATE_LIMIT_MAX_REQUESTS | 60 | 60 | tune by traffic | Per-authenticated-user sync limit |
| OFFLINE_SYNC_INGRESS_RATE_LIMIT_MAX_REQUESTS | 240 | 240 | tune by proxy/NAT topology | Pre-parser IP limit for feature/photo writes |
| PHOTO_MAX_SIZE | 5242880 | 5242880 | policy-driven | Maximum source image bytes |
| PHOTO_MAX_WIDTH | 10000 | 10000 | policy-driven | Maximum decoded image width |
| PHOTO_MAX_HEIGHT | 10000 | 10000 | policy-driven | Maximum decoded image height |
| PHOTO_MAX_PIXELS | 40000000 | 40000000 | policy-driven | Maximum decoded image pixels |
| AUDIT_LOG_ENABLED | true | true | true | Compliance trail |
| METRICS_ENABLED | true | true | true | `/metrics` endpoint |
| METRICS_TOKEN | optional | required | required | Protect metrics endpoint |
| EXPORT_RETENTION_DAYS | 7 | 7 | policy-driven | File lifecycle |
| EXPORT_CLEANUP_INTERVAL_HOURS | 24 | 24 | 24 | Cleanup scheduler |

## First-Time Setup
1. Create DB and enable extensions.
2. Set environment variables from `.env.example`.
3. Install dependencies:
```bash
npm ci
```
4. Apply DB migrations:
```bash
npm run migrate
```
5. Start service:
```bash
npm start
```

## Standard Deployment
1. Pull release artifact/source.
2. Run `npm ci --omit=dev`.
3. Run `npm run migrate`.
4. Restart service.
5. Verify:
```bash
curl -f http://<host>:3000/health
curl -f http://<host>:3000/ready
```

Migration `0039_feature_media_cleanup_jobs.sql` must be applied before serving
feature/photo writes. The cleanup outbox assumes every API replica sees the
same `UPLOAD_DIR`; use shared persistent storage rather than node-local disks.

## Phase 11 Staging Readiness
Before production cutover, run realistic staging data and checks:

```bash
npm run seed:staging
npm run staging:verify
```

Optional all-in-one:
```bash
npm run phase11:staging
```

## Rollback
1. Stop service.
2. Restore previous release artifact.
3. Restore DB from latest known-good backup if schema/data changed incompatibly.
4. Start service and verify `/health`.

## Backups and Restore
### Backup
```bash
pg_dump -Fc -h <db_host> -U <db_user> -d <db_name> -f gis_app_$(date +%F).dump
```

### Restore
```bash
pg_restore -c -h <db_host> -U <db_user> -d <db_name> gis_app_<date>.dump
```

## Security Checklist
- Keep `.env` out of source control.
- Rotate JWT secrets periodically.
- Restrict DB user privileges.
- Enforce HTTPS at reverse proxy.
- Restrict CORS to trusted origins only.
- Monitor auth failures and rate-limit hits.

## Monitoring and Alerts
- Track 5xx rate, latency, and restart count.
- Alert on migration failures.
- Alert on DB connection failures.
- Alert on export processing failures and storage exhaustion.
- Alert when `feature_media_cleanup_job` rows remain due for retry or their
  `attempt_count` continues to increase.

## Incident Response
1. Capture error logs and request IDs.
2. Check DB connectivity and disk space.
3. Temporarily scale down traffic or raise rate limits only if justified.
4. Patch and redeploy with post-incident report.
