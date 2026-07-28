param(
  [string]$ContainerName = 'gis_app-db-1',
  [string]$Database = $(if ($env:POSTGRES_DB) { $env:POSTGRES_DB } else { 'gis_app' }),
  [string]$User = $(if ($env:POSTGRES_USER) { $env:POSTGRES_USER } else { 'gis_user' }),
  [string]$BackupDir = '',
  [switch]$PassThru
)

$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
if (-not $BackupDir) {
  $BackupDir = Join-Path $repoRoot 'backups\db'
}
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
$BackupDir = (Resolve-Path -LiteralPath $BackupDir).Path

$running = docker inspect -f '{{.State.Running}}' $ContainerName 2>$null
if ($LASTEXITCODE -ne 0 -or $running -ne 'true') {
  throw "Database container '$ContainerName' is not running."
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
$fileName = "$Database-$timestamp.dump"
$containerPath = "/tmp/$fileName"
$backupPath = Join-Path $BackupDir $fileName
$manifestPath = "$backupPath.manifest.json"
$dumpValidated = $false

try {
  docker exec $ContainerName pg_dump `
    -U $User `
    -d $Database `
    --format=custom `
    --no-owner `
    --no-privileges `
    --file=$containerPath
  if ($LASTEXITCODE -ne 0) {
    throw 'pg_dump failed.'
  }

  docker exec $ContainerName pg_restore --list $containerPath | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw 'pg_restore could not read the completed dump.'
  }
  $dumpValidated = $true

  docker cp "${ContainerName}:$containerPath" $backupPath
  if ($LASTEXITCODE -ne 0) {
    throw 'docker cp failed while copying the backup out of the database container.'
  }

  $item = Get-Item -LiteralPath $backupPath
  if ($item.Length -le 0) {
    throw 'The copied database dump is empty.'
  }

  $hash = (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $pgDumpVersion = (docker exec $ContainerName pg_dump --version | Select-Object -First 1).Trim()
  if ($LASTEXITCODE -ne 0) {
    throw 'Could not record the pg_dump version.'
  }

  $manifest = [ordered]@{
    schemaVersion = 1
    createdAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    database = $Database
    container = $ContainerName
    databaseUser = $User
    format = 'PostgreSQL custom'
    pgDumpVersion = $pgDumpVersion
    dumpFile = $item.Name
    bytes = $item.Length
    sha256 = $hash
    pgRestoreListValidated = $dumpValidated
  }
  $manifest | ConvertTo-Json -Depth 4 |
    Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM
} catch {
  if (Test-Path -LiteralPath $backupPath) {
    Remove-Item -LiteralPath $backupPath -Force
  }
  if (Test-Path -LiteralPath $manifestPath) {
    Remove-Item -LiteralPath $manifestPath -Force
  }
  throw
} finally {
  docker exec $ContainerName rm -f $containerPath 2>$null | Out-Null
}

$item = Get-Item -LiteralPath $backupPath
Write-Host "[OK] Backup created: $($item.FullName)"
Write-Host "[OK] Size: $([Math]::Round($item.Length / 1MB, 2)) MB"
Write-Host "[OK] SHA-256: $hash"
Write-Host "[OK] Manifest: $manifestPath"

if ($PassThru) {
  [pscustomobject]@{
    BackupPath = $item.FullName
    ManifestPath = (Resolve-Path -LiteralPath $manifestPath).Path
    Sha256 = $hash
    Bytes = $item.Length
  }
}
