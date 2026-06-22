param(
  [Parameter(Mandatory = $true)][string]$BackupPath,
  [string]$ContainerName = 'gis_app-db-1',
  [string]$Database = $(if ($env:POSTGRES_DB) { $env:POSTGRES_DB } else { 'gis_app' }),
  [string]$User = $(if ($env:POSTGRES_USER) { $env:POSTGRES_USER } else { 'gis_user' }),
  [switch]$ConfirmDataLoss,
  [switch]$SkipPreRestoreBackup
)

$ErrorActionPreference = 'Stop'

if (-not $ConfirmDataLoss) {
  throw 'Restore can replace database objects. Re-run with -ConfirmDataLoss after verifying the backup path.'
}

$resolvedBackup = Resolve-Path -LiteralPath $BackupPath
$running = docker inspect -f '{{.State.Running}}' $ContainerName 2>$null
if ($LASTEXITCODE -ne 0 -or $running -ne 'true') {
  throw "Database container '$ContainerName' is not running."
}

if (-not $SkipPreRestoreBackup) {
  Write-Host '[INFO] Creating a pre-restore backup first.'
  & "$PSScriptRoot\backup_db.ps1" `
    -ContainerName $ContainerName `
    -Database $Database `
    -User $User
}

$fileName = Split-Path -Path $resolvedBackup -Leaf
$containerPath = "/tmp/restore-$([guid]::NewGuid().ToString('N'))-$fileName"

try {
  docker cp $resolvedBackup "${ContainerName}:$containerPath"
  if ($LASTEXITCODE -ne 0) {
    throw 'docker cp failed while copying the backup into the database container.'
  }

  docker exec $ContainerName pg_restore `
    -U $User `
    -d $Database `
    --clean `
    --if-exists `
    --no-owner `
    --role=$User `
    $containerPath
  if ($LASTEXITCODE -ne 0) {
    throw 'pg_restore failed.'
  }
} finally {
  docker exec $ContainerName rm -f $containerPath 2>$null | Out-Null
}

Write-Host "[OK] Restore completed from: $resolvedBackup"
