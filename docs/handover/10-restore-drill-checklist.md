# 10 - Restore Drill Checklist

## Objective
Prove backup files can be restored and application behavior is valid after restore.

## Pre-Drill Preparation
- [ ] Confirm the exact source container, database, and user.
- [ ] Confirm free disk capacity for a dump and temporary database.
- [ ] Confirm this is a drill, not an active-database restore.

## Drill Steps
```powershell
.\scripts\dev\restore_drill.ps1 `
  -ContainerName gis_app-db-1 `
  -Database gis_app `
  -User gis_user
```

## Post-Restore Verification
- [ ] SHA-256 matched the manifest.
- [ ] Dump catalog validation passed.
- [ ] Exact row counts matched for every public table.
- [ ] The temporary restore database was removed.
- [ ] The JSON drill report has `status: passed`.

## Drill Evidence
- Keep the ignored dump, manifest, and drill JSON only as long as the local
  rollback policy requires.
- Record the reviewed result in the release evidence; never commit a dump.

## Success Criteria
- Restore completes without errors.
- Exact table names and row counts match.
- Source database is not modified or replaced.
- Temporary restore database is removed.
