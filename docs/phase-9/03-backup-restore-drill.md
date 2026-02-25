# Backup and Restore Drill (Phase 9)

## Objective
Verify that database backups are reliable and restoration is repeatable.

## Prerequisites
- Dockerized PostGIS running (`infra/db/docker-compose.yml`)
- `pg_dump` and `pg_restore` available
- `infra/db/.env` configured

## Backup Execution
```powershell
cd infra/db/scripts
./backup.ps1
```

Expected output:
- Dump file in `infra/db/backups/` with timestamped filename.

## Restore Drill (Staging/Test DB)
1. Use a non-production target DB.
2. Execute:
```powershell
cd infra/db/scripts
./restore.ps1 -DumpFile ..\backups\gis_app_YYYYMMDD_HHMMSS.dump
```
3. Validate:
   - API `GET /ready` returns ready.
   - Key table counts match expected snapshot.
   - Sample auth/project/feature/export workflows work.

## Acceptance Criteria
- Backup completes with zero errors.
- Restore completes with zero errors.
- Data integrity checks pass.
- Drill duration is documented.

## Frequency
- Perform backup daily.
- Perform restore drill at least monthly.

## Incident Recovery Targets
- Target RPO: 24h (or better per policy).
- Target RTO: defined by hosting SLO and tested in drills.
