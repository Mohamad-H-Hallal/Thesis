param(
  [string]$EnvFile = "..\.env",
  [string]$OutputDir = "..\backups",
  [string]$PgDumpBinary = "pg_dump"
)

$ErrorActionPreference = "Stop"

if (!(Test-Path $EnvFile)) {
  throw "Env file not found: $EnvFile"
}

if (!(Test-Path $OutputDir)) {
  New-Item -Path $OutputDir -ItemType Directory | Out-Null
}

$vars = @{}
Get-Content $EnvFile | ForEach-Object {
  $line = $_.Trim()
  if ($line -eq "" -or $line.StartsWith("#")) { return }
  $kv = $line -split "=", 2
  if ($kv.Length -eq 2) {
    $vars[$kv[0].Trim()] = $kv[1].Trim()
  }
}

$dbName = $vars["POSTGRES_DB"]
$dbUser = $vars["POSTGRES_USER"]
$dbPassword = $vars["POSTGRES_PASSWORD"]

if ([string]::IsNullOrWhiteSpace($dbName) -or [string]::IsNullOrWhiteSpace($dbUser) -or [string]::IsNullOrWhiteSpace($dbPassword)) {
  throw "POSTGRES_DB/POSTGRES_USER/POSTGRES_PASSWORD must be set in $EnvFile"
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupPath = Join-Path $OutputDir "gis_app_$timestamp.dump"

$env:PGPASSWORD = $dbPassword
& $PgDumpBinary -h "localhost" -p 5433 -U $dbUser -d $dbName -F c -f $backupPath
if ($LASTEXITCODE -ne 0) {
  throw "pg_dump failed with exit code $LASTEXITCODE"
}

Write-Host "Backup created: $backupPath"
