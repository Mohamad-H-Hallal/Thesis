# 10 - Restore Drill Checklist

## Objective
Prove backup files can be restored and application behavior is valid after restore.

## Pre-Drill Preparation
- [ ] Confirm latest backup file exists (`backups/*.dump`).
- [ ] Confirm target environment and maintenance window.
- [ ] Confirm compose stack file (`compose.prod.yml`).

## Drill Steps
1. Stop application traffic (maintenance mode).
2. Restore database from backup:
```bash
bash ./scripts/restore.sh ./backups/<backup-file>.dump
```
3. Restart stack if needed:
```powershell
docker compose -f compose.prod.yml up -d
```

## Post-Restore Verification
- [ ] `docker compose -f compose.prod.yml ps` shows healthy db/api/nginx.
- [ ] `GET /health` returns 200.
- [ ] `GET /ready` returns 200.
- [ ] Login works with known test user.
- [ ] At least one project and one feature record are queryable.
- [ ] Export request path responds.
- [ ] Audit log writes still function.

## Validation SQL Examples
```sql
SELECT COUNT(*) FROM "user";
SELECT COUNT(*) FROM project;
SELECT COUNT(*) FROM spatial_feature;
SELECT COUNT(*) FROM schema_migrations;
```

## Drill Evidence
- Save command outputs under `docs/handover/evidence`.
- Record timestamp, operator, backup file used, and pass/fail decision.

## Success Criteria
- Restore completes without errors.
- Core API paths and auth are operational.
- Data counts are within expected range.
