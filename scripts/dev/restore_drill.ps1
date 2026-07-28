param(
  [string]$BackupPath = '',
  [string]$ContainerName = 'gis_app-db-1',
  [string]$Database = $(if ($env:POSTGRES_DB) { $env:POSTGRES_DB } else { 'gis_app' }),
  [string]$User = $(if ($env:POSTGRES_USER) { $env:POSTGRES_USER } else { 'gis_user' }),
  [string]$BackupDir = '',
  [string]$EvidencePath = '',
  [switch]$KeepDrillDatabaseOnFailure
)

$ErrorActionPreference = 'Stop'

function Assert-LastExitCode {
  param([Parameter(Mandatory = $true)][string]$Message)
  if ($LASTEXITCODE -ne 0) {
    throw $Message
  }
}

function Get-PublicTableRowCounts {
  param(
    [Parameter(Mandatory = $true)][string]$TargetDatabase,
    [Parameter(Mandatory = $true)][string]$TargetContainer,
    [Parameter(Mandatory = $true)][string]$TargetUser
  )

  $tableSql = "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename"
  $tableNames = @(
    docker exec $TargetContainer psql `
      -U $TargetUser `
      -d $TargetDatabase `
      -At `
      -v ON_ERROR_STOP=1 `
      -c $tableSql
  )
  Assert-LastExitCode "Could not enumerate tables in database '$TargetDatabase'."

  $counts = [ordered]@{}
  foreach ($tableNameValue in $tableNames) {
    $tableName = $tableNameValue.Trim()
    if (-not $tableName) {
      continue
    }
    if ($tableName -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
      throw "Unexpected public table name returned by PostgreSQL: $tableName"
    }

    $countSql = "SELECT COUNT(*)::bigint FROM public.`"$tableName`""
    $countValue = (
      docker exec $TargetContainer psql `
        -U $TargetUser `
        -d $TargetDatabase `
        -At `
        -v ON_ERROR_STOP=1 `
        -c $countSql
    ).Trim()
    Assert-LastExitCode "Could not count rows in $TargetDatabase.public.$tableName."
    $counts[$tableName] = [long]$countValue
  }

  return $counts
}

$running = docker inspect -f '{{.State.Running}}' $ContainerName 2>$null
if ($LASTEXITCODE -ne 0 -or $running -ne 'true') {
  throw "Database container '$ContainerName' is not running."
}

if (-not $BackupPath) {
  $backupParams = @{
    ContainerName = $ContainerName
    Database = $Database
    User = $User
    PassThru = $true
  }
  if ($BackupDir) {
    $backupParams.BackupDir = $BackupDir
  }
  $backupResult = & "$PSScriptRoot\backup_db.ps1" @backupParams
  $BackupPath = $backupResult.BackupPath
}

$resolvedBackup = (Resolve-Path -LiteralPath $BackupPath).Path
$manifestPath = "$resolvedBackup.manifest.json"
if (-not (Test-Path -LiteralPath $manifestPath)) {
  throw "Backup manifest not found: $manifestPath"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.schemaVersion -ne 1 -or -not $manifest.pgRestoreListValidated) {
  throw 'Backup manifest is missing required validation evidence.'
}
if ($manifest.database -ne $Database) {
  throw "Backup manifest database '$($manifest.database)' does not match source '$Database'."
}

$actualHash = (Get-FileHash -LiteralPath $resolvedBackup -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualHash -ne $manifest.sha256) {
  throw 'Backup SHA-256 does not match its manifest.'
}

if (-not $EvidencePath) {
  $EvidencePath = "$resolvedBackup.restore-drill.json"
}
$evidenceParent = Split-Path -Parent $EvidencePath
if ($evidenceParent) {
  New-Item -ItemType Directory -Force -Path $evidenceParent | Out-Null
}

$startedAt = Get-Date
$drillDatabase = "restore_drill_$($startedAt.ToUniversalTime().ToString('yyyyMMddHHmmss'))_$([guid]::NewGuid().ToString('N').Substring(0, 8))"
if ($drillDatabase -notmatch '^restore_drill_[0-9]{14}_[0-9a-f]{8}$') {
  throw "Generated unsafe drill database name: $drillDatabase"
}
if ($drillDatabase -eq $Database) {
  throw 'The restore drill database must never be the source database.'
}

$containerDumpPath = "/tmp/restore-drill-$([guid]::NewGuid().ToString('N')).dump"
$databaseCreated = $false
$databaseDropped = $false
$verificationPassed = $false
$failureMessage = $null
$sourceCounts = $null
$restoredCounts = $null

try {
  $sourceLiteral = $Database.Replace("'", "''")
  $existingSource = (
    docker exec $ContainerName psql `
      -U $User `
      -d $Database `
      -At `
      -v ON_ERROR_STOP=1 `
      -c "SELECT 1 FROM pg_database WHERE datname = '$sourceLiteral'"
  ).Trim()
  Assert-LastExitCode "Could not validate source database '$Database'."
  if ($existingSource -ne '1') {
    throw "Source database '$Database' does not exist."
  }

  docker exec $ContainerName createdb `
    -U $User `
    --owner=$User `
    --template=template0 `
    $drillDatabase
  Assert-LastExitCode "Could not create isolated restore database '$drillDatabase'."
  $databaseCreated = $true

  docker cp $resolvedBackup "${ContainerName}:$containerDumpPath"
  Assert-LastExitCode 'Could not copy the dump into the database container.'

  docker exec $ContainerName pg_restore --list $containerDumpPath | Out-Null
  Assert-LastExitCode 'pg_restore could not read the copied dump.'

  docker exec $ContainerName pg_restore `
    -U $User `
    -d $drillDatabase `
    --exit-on-error `
    --no-owner `
    --no-privileges `
    $containerDumpPath
  Assert-LastExitCode "Restore into isolated database '$drillDatabase' failed."

  $sourceCounts = Get-PublicTableRowCounts `
    -TargetDatabase $Database `
    -TargetContainer $ContainerName `
    -TargetUser $User
  $restoredCounts = Get-PublicTableRowCounts `
    -TargetDatabase $drillDatabase `
    -TargetContainer $ContainerName `
    -TargetUser $User

  $sourceJson = $sourceCounts | ConvertTo-Json -Compress
  $restoredJson = $restoredCounts | ConvertTo-Json -Compress
  if ($sourceJson -ne $restoredJson) {
    throw 'Restored public table names or exact row counts differ from the source database.'
  }

  $verificationPassed = $true
} catch {
  $failureMessage = $_.Exception.Message
} finally {
  docker exec $ContainerName rm -f $containerDumpPath 2>$null | Out-Null

  if ($databaseCreated -and (-not $KeepDrillDatabaseOnFailure -or $verificationPassed)) {
    docker exec $ContainerName dropdb `
      -U $User `
      --if-exists `
      --force `
      $drillDatabase 2>$null
    $databaseDropped = $LASTEXITCODE -eq 0
    if (-not $databaseDropped -and -not $failureMessage) {
      $failureMessage = "Could not remove isolated restore database '$drillDatabase'."
    }
  }
}

$completedAt = Get-Date
$totalRows = 0L
if ($restoredCounts) {
  foreach ($rowCount in $restoredCounts.Values) {
    $totalRows += [long]$rowCount
  }
}

$evidence = [ordered]@{
  schemaVersion = 1
  startedAtUtc = $startedAt.ToUniversalTime().ToString('o')
  completedAtUtc = $completedAt.ToUniversalTime().ToString('o')
  durationSeconds = [Math]::Round(($completedAt - $startedAt).TotalSeconds, 3)
  sourceDatabase = $Database
  temporaryRestoreDatabase = $drillDatabase
  backupFile = (Split-Path -Leaf $resolvedBackup)
  backupSha256 = $actualHash
  checksumVerified = $true
  dumpCatalogValidated = $true
  publicTableCount = if ($restoredCounts) { $restoredCounts.Count } else { 0 }
  restoredTotalRows = $totalRows
  exactRowCountsMatched = $verificationPassed
  temporaryDatabaseDropped = $databaseDropped
  status = if ($verificationPassed -and $databaseDropped) { 'passed' } else { 'failed' }
  failure = $failureMessage
}
$evidence | ConvertTo-Json -Depth 5 |
  Set-Content -LiteralPath $EvidencePath -Encoding utf8NoBOM

if (-not $verificationPassed -or -not $databaseDropped) {
  throw "Restore drill failed: $failureMessage Evidence: $EvidencePath"
}

Write-Host "[OK] Restore drill passed using: $resolvedBackup"
Write-Host "[OK] Exact row counts matched across $($restoredCounts.Count) public tables."
Write-Host "[OK] Temporary database removed: $drillDatabase"
Write-Host "[OK] Evidence: $EvidencePath"
