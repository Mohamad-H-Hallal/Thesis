# Release Checklist (Phase 11 Complete)

## Engineering Gates
- [x] Backend `npm ci`
- [x] Backend `npm run lint`
- [x] Backend `npm run typecheck`
- [x] Backend `npm run test:ci`
- [x] Backend `npm run build`
- [x] Backend `npm run audit:prod` (0 vulnerabilities)
- [x] Mobile `flutter pub get`
- [x] Mobile `flutter analyze`
- [x] Mobile `flutter test --coverage`
- [x] Mobile `flutter build web`
- [x] Mobile `flutter build apk`
- [x] DB migrations from scratch succeed
- [x] DB drift check on existing state succeeds (no pending migrations)
- [x] OpenAPI contract check passes and uses `/api/v1`
- [x] Public role escalation blocked in signup
- [x] Production metrics endpoint protected by token

## Docker Release Gates
- [x] `docker compose -f docker-compose.yml up -d --build`
- [x] `docker compose -f docker-compose.yml ps` shows `db` and `api` healthy
- [x] `migrate` service completes successfully
- [x] Nginx serves `/api/v1` and `/docs/openapi.yaml`
- [x] Smoke test passes end-to-end

## Verification Commands (Production Stack)
```powershell
cd D:\GIS_APP
docker compose -f docker-compose.yml up -d --build
docker compose -f docker-compose.yml ps
powershell -ExecutionPolicy Bypass -File .\scripts\smoke-test.ps1 -SkipUp
```

## Rollback Steps
1. Identify last known-good release tag/image.
2. Pull previous release branch/tag.
3. Recreate services with previous artifact:
```powershell
git checkout <known-good-tag>
docker compose -f docker-compose.yml down
docker compose -f docker-compose.yml up -d --build
```
4. If schema/data incompatibility occurred, restore DB and storage backups:
```powershell
cd infra\db\scripts
./restore.ps1 -DumpFile ..\backups\<known-good>.dump -EnvFile ..\.env
```
5. Re-run smoke test before reopening traffic.

## Emergency Stop / Safe Recovery
```powershell
docker compose -f docker-compose.yml stop
docker compose -f docker-compose.yml logs --tail=200 api
docker compose -f docker-compose.yml logs --tail=200 db
docker compose -f docker-compose.yml up -d
```

## Evidence Files
- `docs/handover/evidence/backend-npm-ci.log`
- `docs/handover/evidence/backend-lint-phase11.log`
- `docs/handover/evidence/backend-typecheck-phase11.log`
- `docs/handover/evidence/backend-test-ci-phase11.log`
- `docs/handover/evidence/backend-build-phase11.log`
- `docs/handover/evidence/backend-audit-prod-phase11.log`
- `docs/handover/evidence/mobile-pub-get-phase11.log`
- `docs/handover/evidence/mobile-analyze-phase11.log`
- `docs/handover/evidence/mobile-test-coverage-phase11.log`
- `docs/handover/evidence/mobile-build-web-phase11.log`
- `docs/handover/evidence/mobile-build-apk-phase11.log`
- `docs/handover/evidence/db-migrate-from-scratch-phase11.log`
- `docs/handover/evidence/db-migrate-drift-check-phase11.log`
- `docs/handover/evidence/docker-up.log`
- `docs/handover/evidence/docker-endpoints-phase11.log`
- `docs/handover/evidence/smoke-test.log`
- `docs/handover/evidence/docker-down-after-smoke-phase11.log`
