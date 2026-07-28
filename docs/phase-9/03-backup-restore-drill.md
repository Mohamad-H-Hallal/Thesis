# Backup and Restore Drill (Phase 9)

## Objective
Verify that database backups are reliable and restoration is repeatable.

## Prerequisites
- Dockerized PostGIS running
- PowerShell 7 and Docker available
- The exact source container, database, and database user are known

## Safe Isolated Drill
```powershell
.\scripts\dev\restore_drill.ps1 `
  -ContainerName gis_app-db-1 `
  -Database gis_app `
  -User gis_user
```

Expected output:
- dump, SHA-256 manifest, and drill report under ignored `backups/db/`;
- successful `pg_restore --list`;
- restore into a uniquely named temporary database;
- exact public table names and row counts match;
- temporary database is removed.

## Acceptance Criteria
- Backup completes with zero errors.
- Restore completes with zero errors.
- Data integrity checks pass.
- Drill duration is documented.

## Frequency
- Perform backup daily.
- Perform restore drill at least monthly.

## Incident Recovery Targets
- Authoritative pre-deployment targets:
  `docs/predeployment/phase-1-data-safety-foundation.md`.
