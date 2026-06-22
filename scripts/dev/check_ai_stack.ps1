param(
  [string]$BackendUrl = $(if ($env:APP_PUBLIC_API_URL) { $env:APP_PUBLIC_API_URL } else { 'http://127.0.0.1:3000' }),
  [string]$AiServerUrl = $(if ($env:AI_SERVER_URL) { $env:AI_SERVER_URL } else { 'http://127.0.0.1:8000' }),
  [string]$AuthToken = $env:TEST_AUTH_TOKEN,
  [string]$ProjectId = $env:TEST_PROJECT_ID
)

$ErrorActionPreference = 'Stop'
$script:failed = $false

function Write-Result {
  param(
    [Parameter(Mandatory = $true)][string]$Level,
    [Parameter(Mandatory = $true)][string]$Message
  )
  Write-Host "[$Level] $Message"
  if ($Level -eq 'FAIL') {
    $script:failed = $true
  }
}

function Invoke-Json {
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [hashtable]$Headers = @{}
  )
  try {
    $payload = Invoke-RestMethod -Uri $Uri -Headers $Headers -TimeoutSec 8
    return @{ Ok = $true; Payload = $payload; Error = $null }
  } catch {
    return @{ Ok = $false; Payload = $null; Error = $_.Exception.Message }
  }
}

function Read-Property {
  param(
    [object]$Value,
    [Parameter(Mandatory = $true)][string]$Name
  )
  if ($null -eq $Value) {
    return $null
  }
  $property = $Value.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $null
  }
  return $property.Value
}

$backendHealth = Invoke-Json "$BackendUrl/health"
if ($backendHealth.Ok) {
  Write-Result 'OK' "Backend health endpoint responded at $BackendUrl/health"
} else {
  Write-Result 'FAIL' "Backend health endpoint failed at $BackendUrl/health: $($backendHealth.Error)"
}

$aiHealth = Invoke-Json "$AiServerUrl/health"
if ($aiHealth.Ok) {
  $status = Read-Property $aiHealth.Payload 'status'
  $dryRun = Read-Property $aiHealth.Payload 'dry_run'
  $checks = Read-Property $aiHealth.Payload 'checks'
  $dbConfigured = Read-Property $checks 'database'
  $geeConfigured = Read-Property $checks 'gee'
  if ($status -eq 'ok') {
    Write-Result 'OK' "AI server connected at $AiServerUrl/health (dry_run=$dryRun)"
  } elseif ($status -eq 'degraded') {
    Write-Result 'WARN' "AI server is degraded at $AiServerUrl/health (dry_run=$dryRun)"
  } else {
    Write-Result 'FAIL' "AI server health returned status '$status' at $AiServerUrl/health"
  }
  if ($dryRun -eq $false) {
    Write-Result 'OK' 'AI_DRY_RUN=false; smoke is checking the real AI path.'
  } else {
    Write-Result 'FAIL' 'AI_DRY_RUN=true; this is test mode, not the real AI path.'
  }
  if ($dbConfigured -eq $true) {
    Write-Result 'OK' 'AI server database check passed.'
  } else {
    Write-Result 'FAIL' "AI server database check did not pass (value=$dbConfigured)."
  }
  if ($geeConfigured -eq $true) {
    Write-Result 'OK' 'AI server GEE credential check passed.'
  } else {
    Write-Result 'FAIL' "AI server GEE credential check did not pass (value=$geeConfigured)."
  }
} else {
  Write-Result 'FAIL' "AI server unavailable at $AiServerUrl/health: $($aiHealth.Error)"
}

if ($AuthToken -and $ProjectId) {
  $headers = @{ Authorization = "Bearer $AuthToken" }
  $readiness = Invoke-Json "$BackendUrl/api/v1/projects/$ProjectId/ai/readiness" $headers
  if ($readiness.Ok) {
    $data = Read-Property $readiness.Payload 'data'
    $readinessBody = Read-Property $data 'readiness'
    $aiServer = Read-Property $readinessBody 'ai_server'
    $configured = Read-Property $aiServer 'configured'
    $available = Read-Property $aiServer 'available'
    $status = Read-Property $aiServer 'status'
    $callbackSecretConfigured = Read-Property $aiServer 'callback_secret_configured'

    if ($configured -ne $true) {
      Write-Result 'FAIL' 'AI_SERVER_URL missing on backend readiness.'
    } elseif ($available -eq $true) {
      Write-Result 'OK' 'Backend readiness sees AI server connected.'
    } elseif ($status -eq 'degraded') {
      Write-Result 'WARN' 'Backend readiness sees AI server degraded.'
    } else {
      Write-Result 'FAIL' "Backend readiness sees AI server unavailable (status=$status)."
    }

    if ($callbackSecretConfigured -eq $true) {
      Write-Result 'OK' 'Backend readiness sees callback secret configured.'
    } else {
      Write-Result 'FAIL' 'Callback secret missing on backend readiness.'
    }
  } else {
    Write-Result 'FAIL' "Authenticated AI readiness check failed: $($readiness.Error)"
  }
} else {
  Write-Result 'INFO' 'Backend AI readiness endpoint skipped. Provide a smoke auth token/project, or run smoke_ai_* with -AutoAuth -AutoProject.'
}

if ($script:failed) {
  exit 1
}
