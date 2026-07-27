# Infra DB Operations

This folder is for DB maintenance utilities, not the main app runtime.

Official runtime:
- start the app from the repo root with `docker compose up -d db migrate api`
- compose-backed PostGIS is exposed on `localhost:54329`

Do not start `infra/db/docker-compose.yml` for normal app usage unless you intentionally need an isolated standalone PostGIS/Adminer stack for separate experiments.

## Backup (Windows PowerShell)
```powershell
cd infra/db/scripts
./backup.ps1
```

Optional parameters:
```powershell
./backup.ps1 -EnvFile ..\.env -OutputDir ..\backups -PgDumpBinary pg_dump
```

Defaults:
- `POSTGRES_HOST=localhost`
- `POSTGRES_PORT=54329`

## Restore (Windows PowerShell)
```powershell
cd infra/db/scripts
./restore.ps1 -DumpFile ..\backups\gis_app_YYYYMMDD_HHMMSS.dump
```

## Notes
- Scripts read credentials from `infra/db/.env`.
- `infra/db/.env.example` now targets the official compose-backed DB by default.
- Keep backup files outside git and in encrypted storage.
- Run restore drills on staging before production incidents.
