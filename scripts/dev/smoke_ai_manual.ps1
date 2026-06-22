param(
  [string]$BackendUrl = $(if ($env:APP_PUBLIC_API_URL) { $env:APP_PUBLIC_API_URL } else { 'http://127.0.0.1:3000' }),
  [string]$AiServerUrl = $(if ($env:AI_SERVER_URL) { $env:AI_SERVER_URL } else { 'http://127.0.0.1:8000' }),
  [string]$AuthToken = $env:TEST_AUTH_TOKEN,
  [string]$ProjectId = $env:TEST_PROJECT_ID,
  [string]$Email = $env:TEST_EMAIL,
  [string]$Password = $env:TEST_PASSWORD,
  [switch]$AutoAuth,
  [switch]$AutoProject,
  [switch]$StartRun,
  [int]$PollSeconds = 20
)

$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
. "$PSScriptRoot\ai_smoke_common.ps1"
$dotEnv = Read-AiSmokeDotEnv -Paths @(
  (Join-Path $repoRoot '.env'),
  (Join-Path $repoRoot 'apps\api\.env')
)

$auth = Resolve-AiSmokeAuth `
  -BackendUrl $BackendUrl `
  -AuthToken $AuthToken `
  -AutoAuth:$AutoAuth `
  -Email $Email `
  -Password $Password `
  -DotEnv $dotEnv

$resolvedToken = if ($auth.Success) { $auth.Token } else { $null }
$project = [pscustomobject]@{ Valid = $false; ProjectId = $ProjectId; Reason = 'project not resolved' }
if ($resolvedToken) {
  $project = Resolve-AiSmokeProject `
    -BackendUrl $BackendUrl `
    -AuthToken $resolvedToken `
    -ProjectId $ProjectId `
    -AutoProject:$AutoProject
}

& "$PSScriptRoot\check_ai_stack.ps1" `
  -BackendUrl $BackendUrl `
  -AiServerUrl $AiServerUrl `
  -AuthToken $resolvedToken `
  -ProjectId $project.ProjectId

if (-not $StartRun) {
  Write-Host '[INFO] Start AI Run skipped. Pass -StartRun to create a real backend AI run.'
  exit 0
}

if (-not $auth.Success) {
  Write-Host '[FAIL] Cannot start AI run without authentication. Use -AutoAuth or TEST_AUTH_TOKEN.'
  exit 1
}
if (-not $project.Valid) {
  Write-Host "[FAIL] Cannot start AI run without an AI-ready project. Use -AutoProject or TEST_PROJECT_ID. Reason: $($project.Reason)"
  exit 1
}

$readiness = $project.Readiness
$readinessStatus = Read-AiSmokeProperty $readiness 'status'
$blockers = @(Read-AiSmokeProperty $readiness 'blockers')
$warnings = @(Read-AiSmokeProperty $readiness 'warnings')
if ($readinessStatus -eq 'not_ready') {
  Write-Host "[FAIL] Readiness is not ready: $($blockers -join '; ')"
  exit 1
}
Write-Host "[OK] Readiness status for selected project: $readinessStatus"
if ($warnings.Count -gt 0) {
  Write-Host "[WARN] Readiness warnings: $($warnings -join '; ')"
}

$headers = @{ Authorization = "Bearer $($auth.Token)" }
$body = @{
  status = 'starting'
  execution_mode = 'regional_full_review_artifacts'
}
if (-not [string]::IsNullOrWhiteSpace($project.LabelField)) {
  $body.label_field = $project.LabelField
}
if ($project.MinSamplesPerClass) {
  $body.min_samples_per_class = [int]$project.MinSamplesPerClass
}

$created = Invoke-AiSmokeJson `
  -Method Post `
  -Uri "$BackendUrl/api/v1/projects/$($project.ProjectId)/ai/runs" `
  -Headers $headers `
  -Body $body `
  -TimeoutSec 30
if (-not $created.Ok) {
  Write-Host "[FAIL] Real AI run creation failed: $($created.Error)"
  exit 1
}

$createdData = Read-AiSmokeProperty $created.Payload 'data'
$runId = Read-AiSmokeProperty $createdData 'id'
if ([string]::IsNullOrWhiteSpace($runId)) {
  Write-Host '[FAIL] Start AI Run response did not include data.id.'
  exit 1
}
$isDryRun = Read-AiSmokeProperty $createdData 'is_dry_run'
$createdStatus = Read-AiSmokeProperty $createdData 'status'
Write-Host "[OK] Real AI run created: $runId"
Write-Host "[INFO] Created run status: $createdStatus"
if ($isDryRun -eq $true) {
  Write-Host '[FAIL] Created run is marked dry-run; expected real mode.'
  exit 1
}
Write-Host '[OK] Created run is real mode (is_dry_run=false).'

$deadline = (Get-Date).AddSeconds($PollSeconds)
$lastStatus = $null
do {
  Start-Sleep -Seconds 2
  $statusResponse = Invoke-AiSmokeJson `
    -Uri "$BackendUrl/api/v1/projects/$($project.ProjectId)/ai/runs/$runId/status" `
    -Headers $headers `
    -TimeoutSec 15
  if (-not $statusResponse.Ok) {
    Write-Host "[FAIL] Run status request failed: $($statusResponse.Error)"
    exit 1
  }
  $statusData = Read-AiSmokeProperty $statusResponse.Payload 'data'
  $runStatus = Read-AiSmokeProperty $statusData 'status'
  $stage = Read-AiSmokeProperty $statusData 'stage'
  $message = Read-AiSmokeProperty $statusData 'message'
  if ($runStatus -ne $lastStatus) {
    Write-Host "[INFO] Run $runId status=$runStatus stage=$stage message=$message"
    $lastStatus = $runStatus
  }
  if (@('completed', 'failed', 'cancelled') -contains ([string]$runStatus).ToLowerInvariant()) {
    if ($runStatus -eq 'completed') {
      Write-Host '[OK] Real AI run reached completed status during smoke polling.'
      exit 0
    }
    Write-Host "[FAIL] Real AI run reached terminal status $runStatus. This is a real pipeline/backend failure, not fake smoke data."
    exit 1
  }
} while ((Get-Date) -lt $deadline)

Write-Host "[OK] Real AI run was accepted and remained active after $PollSeconds seconds of smoke polling."
exit 0
