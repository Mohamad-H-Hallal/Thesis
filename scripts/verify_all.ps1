param(
  [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')),
  [string]$ComposeFile = 'compose.prod.yml',
  [string]$EvidenceDir = '',
  [switch]$SkipMobileBuild
)

$ErrorActionPreference = 'Stop'
$evidenceDir = if ($EvidenceDir) { $EvidenceDir } else { Join-Path $RepoRoot 'docs/handover/evidence' }
New-Item -ItemType Directory -Force $evidenceDir | Out-Null

function Invoke-Step {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Command,
    [Parameter(Mandatory = $true)][string]$WorkDir,
    [Parameter(Mandatory = $true)][string]$LogFile
  )

  Write-Host "`n=== $Name ==="
  Push-Location $WorkDir
  try {
    $cmdLine = "$Command 2>&1"
    cmd /c $cmdLine | Tee-Object -FilePath $LogFile
    if ($LASTEXITCODE -ne 0) {
      throw "Step failed ($Name) with exit code $LASTEXITCODE"
    }
  } finally {
    Pop-Location
  }
}

Invoke-Step -Name 'Docker compose config validation' -Command "docker compose -f $ComposeFile config" -WorkDir $RepoRoot -LogFile (Join-Path $evidenceDir 'verify-docker-config.log')
Invoke-Step -Name 'Dev PostGIS for backend tests' -Command 'docker compose up -d db' -WorkDir $RepoRoot -LogFile (Join-Path $evidenceDir 'verify-dev-db-up.log')

$apiDir = Join-Path $RepoRoot 'apps/api'
Invoke-Step -Name 'API npm ci' -Command 'npm ci' -WorkDir $apiDir -LogFile (Join-Path $evidenceDir 'verify-backend-npm-ci.log')
Invoke-Step -Name 'Legal readiness report (expected to remain blocked until approvals)' -Command 'npm run legal:readiness:report' -WorkDir $apiDir -LogFile (Join-Path $evidenceDir 'verify-legal-readiness.log')
Invoke-Step -Name 'API lint' -Command 'npm run lint' -WorkDir $apiDir -LogFile (Join-Path $evidenceDir 'verify-backend-lint.log')
Invoke-Step -Name 'API typecheck' -Command 'npm run typecheck' -WorkDir $apiDir -LogFile (Join-Path $evidenceDir 'verify-backend-typecheck.log')
Invoke-Step -Name 'API tests' -Command 'npm run test:ci' -WorkDir $apiDir -LogFile (Join-Path $evidenceDir 'verify-backend-test-ci.log')
Invoke-Step -Name 'API build' -Command 'npm run build' -WorkDir $apiDir -LogFile (Join-Path $evidenceDir 'verify-backend-build.log')
Invoke-Step -Name 'API production audit' -Command 'npm run audit:prod' -WorkDir $apiDir -LogFile (Join-Path $evidenceDir 'verify-backend-audit-prod.log')

$mobileDir = Join-Path $RepoRoot 'apps/mobile'
Invoke-Step -Name 'Mobile pub get' -Command 'flutter pub get' -WorkDir $mobileDir -LogFile (Join-Path $evidenceDir 'verify-mobile-pub-get.log')
Invoke-Step -Name 'Mobile analyze' -Command 'flutter analyze' -WorkDir $mobileDir -LogFile (Join-Path $evidenceDir 'verify-mobile-analyze.log')
Invoke-Step -Name 'Mobile tests' -Command 'flutter test --coverage' -WorkDir $mobileDir -LogFile (Join-Path $evidenceDir 'verify-mobile-test-coverage.log')

if (-not $SkipMobileBuild) {
  Invoke-Step -Name 'Mobile build web' -Command 'flutter build web' -WorkDir $mobileDir -LogFile (Join-Path $evidenceDir 'verify-mobile-build-web.log')
  Invoke-Step -Name 'Mobile build apk' -Command 'flutter build apk' -WorkDir $mobileDir -LogFile (Join-Path $evidenceDir 'verify-mobile-build-apk.log')
}

Write-Host "`nAll release verification checks completed successfully."
