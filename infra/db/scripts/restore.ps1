param(
  [Parameter(Mandatory = $true)]
  [string]$DumpFile,
  [string]$EnvFile = "..\.env",
  [string]$PgRestoreBinary = "pg_restore",
  [string]$PgHost = "",
  [string]$PgPort = ""
)

$ErrorActionPreference = "Stop"

if (!(Test-Path $DumpFile)) {
  throw "Dump file not found: $DumpFile"
}

if (!(Test-Path $EnvFile)) {
  throw "Env file not found: $EnvFile"
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
$dbHost = if ([string]::IsNullOrWhiteSpace($PgHost)) { $vars["POSTGRES_HOST"] } else { $PgHost }
$dbPort = if ([string]::IsNullOrWhiteSpace($PgPort)) { $vars["POSTGRES_PORT"] } else { $PgPort }

if ([string]::IsNullOrWhiteSpace($dbName) -or [string]::IsNullOrWhiteSpace($dbUser) -or [string]::IsNullOrWhiteSpace($dbPassword)) {
  throw "POSTGRES_DB/POSTGRES_USER/POSTGRES_PASSWORD must be set in $EnvFile"
}

$dbHost = if ([string]::IsNullOrWhiteSpace($dbHost)) { "localhost" } else { $dbHost }
$dbPort = if ([string]::IsNullOrWhiteSpace($dbPort)) { "55433" } else { $dbPort }

$env:PGPASSWORD = $dbPassword
& $PgRestoreBinary -h $dbHost -p $dbPort -U $dbUser -d $dbName -c $DumpFile
if ($LASTEXITCODE -ne 0) {
  throw "pg_restore failed with exit code $LASTEXITCODE"
}

Write-Host "Restore completed from: $DumpFile"
