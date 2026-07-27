# Release Checklist (Phase 11)

## A) Backend Quality Gates
- [x] `npm ci`
- [x] `npm run lint`
- [x] `npm run typecheck`
- [x] `npm run test:ci`
- [x] `npm run build`
- [x] `npm run audit:prod`
- [x] `npm run openapi:check`

## B) Mobile Quality Gates
- [x] `flutter pub get`
- [x] `flutter analyze`
- [x] `flutter test --coverage`
- [x] `flutter build web`
- [x] `flutter build apk`

## C) Docker/Deploy Gates
- [x] `docker compose -f compose.prod.yml config`
- [x] `docker compose -f compose.prod.yml up -d --build`
- [x] Host port conflict handled (`NGINX_HTTP_PORT=8088` used in local verification)
- [x] DB/API/nginx healthchecks pass
- [x] migration service runs successfully from `infra/migrations`
- [x] smoke test passes (`scripts/smoke-test.ps1`)
- [x] `/metrics` protected when configured

## D) Security Gates
- [x] Public signup cannot create admin
- [x] API versioning aligned to `/api/v1`
- [x] OpenAPI core paths validated
- [x] `.env` files ignored; examples only committed
- [x] Secrets scan completed

## E) Port Conflict Gate
- [x] 5433 conflict root cause identified (`gis_app_db`)
- [x] compose.prod keeps DB internal-only
- [x] dev override uses configurable DB host port `POSTGRES_HOST_PORT` with default `54329`

## F) Release Verification Script
- [x] Windows one-command gate: `scripts/verify_all.ps1`

Run:
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\verify_all.ps1
```

## G) Rollback Steps
1. Stop current stack:
```powershell
docker compose -f compose.prod.yml down
```
2. Checkout previous tag and redeploy:
```powershell
git checkout <previous-stable-tag>
docker compose -f compose.prod.yml up -d --build
```
3. Restore DB if schema/data rollback required:
```bash
bash ./scripts/restore.sh ./backups/<known-good>.dump
```
4. Run smoke test before reopening traffic.

## Evidence
- `docs/handover/evidence/*`
