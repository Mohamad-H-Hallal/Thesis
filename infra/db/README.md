# Infra DB Operations

## Backup (Windows PowerShell)
```powershell
cd infra/db/scripts
./backup.ps1
```

Optional parameters:
```powershell
./backup.ps1 -EnvFile ..\.env -OutputDir ..\backups -PgDumpBinary pg_dump
```

## Restore (Windows PowerShell)
```powershell
cd infra/db/scripts
./restore.ps1 -DumpFile ..\backups\gis_app_YYYYMMDD_HHMMSS.dump
```

## Notes
- Scripts read credentials from `infra/db/.env`.
- Keep backup files outside git and in encrypted storage.
- Run restore drills on staging before production incidents.
