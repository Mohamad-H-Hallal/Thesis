param(
  [string]$ContainerName = 'gis_app-db-1',
  [string]$Database = $(if ($env:POSTGRES_DB) { $env:POSTGRES_DB } else { 'gis_app' }),
  [string]$User = $(if ($env:POSTGRES_USER) { $env:POSTGRES_USER } else { 'gis_user' }),
  [string]$BackupDir = ''
)

$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
if (-not $BackupDir) {
  $BackupDir = Join-Path $repoRoot 'backups\db'
}
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

$running = docker inspect -f '{{.State.Running}}' $ContainerName 2>$null
if ($LASTEXITCODE -ne 0 -or $running -ne 'true') {
  throw "Database container '$ContainerName' is not running."
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$fileName = "$Database-$timestamp.dump"
$containerPath = "/tmp/$fileName"
$backupPath = Join-Path $BackupDir $fileName

try {
  docker exec $ContainerName pg_dump -U $User -d $Database -Fc -f $containerPath
  if ($LASTEXITCODE -ne 0) {
    throw 'pg_dump failed.'
  }

  docker cp "${ContainerName}:$containerPath" $backupPath
  if ($LASTEXITCODE -ne 0) {
    throw 'docker cp failed while copying the backup out of the database container.'
  }
} finally {
  docker exec $ContainerName rm -f $containerPath 2>$null | Out-Null
}

$item = Get-Item -LiteralPath $backupPath
Write-Host "[OK] Backup created: $($item.FullName)"
Write-Host "[OK] Size: $([Math]::Round($item.Length / 1MB, 2)) MB"
