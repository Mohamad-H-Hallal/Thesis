$ErrorActionPreference = 'Stop'

function Read-AiSmokeDotEnv {
  param([Parameter(Mandatory = $true)][string[]]$Paths)
  $values = @{}
  foreach ($path in $Paths) {
    if (-not (Test-Path -LiteralPath $path)) {
      continue
    }
    foreach ($line in Get-Content -LiteralPath $path) {
      if ($line -match '^\s*#' -or $line -notmatch '=') {
        continue
      }
      $parts = $line -split '=', 2
      $key = $parts[0].Trim()
      if (-not $key) {
        continue
      }
      $values[$key] = $parts[1].Trim().Trim('"').Trim("'")
    }
  }
  return $values
}

function Get-AiSmokeValue {
  param(
    [hashtable]$DotEnv,
    [string]$ExplicitValue,
    [Parameter(Mandatory = $true)][string[]]$EnvNames
  )
  if (-not [string]::IsNullOrWhiteSpace($ExplicitValue)) {
    return $ExplicitValue
  }
  foreach ($name in $EnvNames) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      return $value
    }
  }
  foreach ($name in $EnvNames) {
    if ($DotEnv.ContainsKey($name) -and -not [string]::IsNullOrWhiteSpace($DotEnv[$name])) {
      return $DotEnv[$name]
    }
  }
  return $null
}

function Read-AiSmokeProperty {
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

function Invoke-AiSmokeJson {
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [ValidateSet('Get', 'Post')][string]$Method = 'Get',
    [hashtable]$Headers = @{},
    [object]$Body = $null,
    [int]$TimeoutSec = 20
  )
  try {
    $invokeArgs = @{
      Uri = $Uri
      Method = $Method
      Headers = $Headers
      TimeoutSec = $TimeoutSec
    }
    if ($null -ne $Body) {
      $invokeArgs.ContentType = 'application/json'
      $invokeArgs.Body = ($Body | ConvertTo-Json -Depth 12)
    }
    $payload = Invoke-RestMethod @invokeArgs
    return [pscustomobject]@{ Ok = $true; Payload = $payload; Error = $null }
  } catch {
    return [pscustomobject]@{ Ok = $false; Payload = $null; Error = $_.Exception.Message }
  }
}

function Resolve-AiSmokeAuth {
  param(
    [Parameter(Mandatory = $true)][string]$BackendUrl,
    [string]$AuthToken,
    [switch]$AutoAuth,
    [string]$Email,
    [string]$Password,
    [hashtable]$DotEnv = @{}
  )
  if (-not [string]::IsNullOrWhiteSpace($AuthToken)) {
    Write-Host '[OK] Authentication token supplied for smoke script.'
    return [pscustomobject]@{ Success = $true; Token = $AuthToken; Source = 'token'; User = $null }
  }
  if (-not $AutoAuth) {
    Write-Host '[INFO] Authenticated checks skipped. Pass -AutoAuth or set TEST_AUTH_TOKEN.'
    return [pscustomobject]@{ Success = $false; Token = $null; Source = 'none'; User = $null }
  }

  $resolvedEmail = Get-AiSmokeValue -DotEnv $DotEnv -ExplicitValue $Email -EnvNames @('TEST_EMAIL', 'SUPER_ADMIN_EMAIL')
  $resolvedPassword = Get-AiSmokeValue -DotEnv $DotEnv -ExplicitValue $Password -EnvNames @('TEST_PASSWORD', 'SUPER_ADMIN_PASSWORD')
  if ([string]::IsNullOrWhiteSpace($resolvedEmail) -or [string]::IsNullOrWhiteSpace($resolvedPassword)) {
    Write-Host '[FAIL] Auto-auth could not find TEST_EMAIL/TEST_PASSWORD or SUPER_ADMIN_EMAIL/SUPER_ADMIN_PASSWORD.'
    return [pscustomobject]@{ Success = $false; Token = $null; Source = 'missing_credentials'; User = $null }
  }

  $login = Invoke-AiSmokeJson `
    -Method Post `
    -Uri "$BackendUrl/api/v1/auth/login" `
    -Body @{ email = $resolvedEmail; password = $resolvedPassword }
  if (-not $login.Ok) {
    Write-Host "[FAIL] Authenticated login failed: $($login.Error)"
    return [pscustomobject]@{ Success = $false; Token = $null; Source = 'login_failed'; User = $null }
  }

  $data = Read-AiSmokeProperty $login.Payload 'data'
  $token = Read-AiSmokeProperty $data 'token'
  $user = Read-AiSmokeProperty $data 'user'
  $role = Read-AiSmokeProperty $user 'role'
  $isProtected = Read-AiSmokeProperty $user 'is_protected_super_admin'
  if ([string]::IsNullOrWhiteSpace($token)) {
    Write-Host '[FAIL] Login response did not include an access token.'
    return [pscustomobject]@{ Success = $false; Token = $null; Source = 'missing_token'; User = $user }
  }
  if ($role -ne 'admin' -or $isProtected -ne $true) {
    Write-Host '[FAIL] Login succeeded, but Start AI Run requires the protected super-admin account.'
    return [pscustomobject]@{ Success = $false; Token = $null; Source = 'wrong_role'; User = $user }
  }

  Write-Host '[OK] Authenticated login succeeded as protected super-admin.'
  return [pscustomobject]@{ Success = $true; Token = $token; Source = 'login'; User = $user }
}

function Test-AiSmokeProject {
  param(
    [Parameter(Mandatory = $true)][string]$BackendUrl,
    [Parameter(Mandatory = $true)][string]$AuthToken,
    [Parameter(Mandatory = $true)][string]$ProjectId,
    [string]$ProjectName = ''
  )
  $headers = @{ Authorization = "Bearer $AuthToken" }
  $settingsResponse = Invoke-AiSmokeJson -Uri "$BackendUrl/api/v1/projects/$ProjectId/ai/settings" -Headers $headers
  if (-not $settingsResponse.Ok) {
    return [pscustomobject]@{
      Valid = $false; ProjectId = $ProjectId; ProjectName = $ProjectName
      Reason = "settings unavailable: $($settingsResponse.Error)"
      Settings = $null; Readiness = $null; ActiveRun = $null
    }
  }
  $settings = Read-AiSmokeProperty $settingsResponse.Payload 'data'
  $isEnabled = Read-AiSmokeProperty $settings 'is_enabled'
  $labelField = Read-AiSmokeProperty $settings 'label_field'
  $minSamples = Read-AiSmokeProperty $settings 'min_samples_per_class'

  $readinessResponse = Invoke-AiSmokeJson -Uri "$BackendUrl/api/v1/projects/$ProjectId/ai/readiness" -Headers $headers
  if (-not $readinessResponse.Ok) {
    return [pscustomobject]@{
      Valid = $false; ProjectId = $ProjectId; ProjectName = $ProjectName
      Reason = "readiness unavailable: $($readinessResponse.Error)"
      Settings = $settings; Readiness = $null; ActiveRun = $null
    }
  }
  $readinessData = Read-AiSmokeProperty $readinessResponse.Payload 'data'
  $readiness = Read-AiSmokeProperty $readinessData 'readiness'
  $readinessStatus = Read-AiSmokeProperty $readiness 'status'
  $blockers = @(Read-AiSmokeProperty $readiness 'blockers')
  $aiServer = Read-AiSmokeProperty $readiness 'ai_server'
  $aiServerConnected =
    (Read-AiSmokeProperty $aiServer 'configured') -eq $true -and
    (Read-AiSmokeProperty $aiServer 'available') -eq $true -and
    (Read-AiSmokeProperty $aiServer 'status') -eq 'ok'

  $runsResponse = Invoke-AiSmokeJson -Uri "$BackendUrl/api/v1/projects/$ProjectId/ai/runs?limit=50" -Headers $headers
  $activeRun = $null
  if ($runsResponse.Ok) {
    $runs = @(Read-AiSmokeProperty $runsResponse.Payload 'data')
    $activeStatuses = @(
      'created', 'accepted', 'queued', 'starting', 'running', 'cancelling',
      'resuming', 'extracting_features', 'training', 'evaluating', 'classifying'
    )
    foreach ($run in $runs) {
      $status = [string](Read-AiSmokeProperty $run 'status')
      if ($activeStatuses -contains $status.ToLowerInvariant()) {
        $activeRun = $run
        break
      }
    }
  }

  $reasons = @()
  if ($isEnabled -ne $true) { $reasons += 'AI settings are not enabled' }
  if ([string]::IsNullOrWhiteSpace($labelField)) { $reasons += 'AI label field is missing' }
  if ($readinessStatus -eq 'not_ready') {
    $reasonText = if ($blockers.Count -gt 0) { ($blockers -join '; ') } else { 'readiness is not ready' }
    $reasons += $reasonText
  }
  if (-not $aiServerConnected) { $reasons += 'backend readiness does not see AI server connected' }
  if ($null -ne $activeRun) {
    $reasons += "active run already exists: $(Read-AiSmokeProperty $activeRun 'id')"
  }

  return [pscustomobject]@{
    Valid = ($reasons.Count -eq 0)
    ProjectId = $ProjectId
    ProjectName = $ProjectName
    Reason = ($reasons -join '; ')
    Settings = $settings
    Readiness = $readiness
    ActiveRun = $activeRun
    LabelField = $labelField
    MinSamplesPerClass = $minSamples
  }
}

function Resolve-AiSmokeProject {
  param(
    [Parameter(Mandatory = $true)][string]$BackendUrl,
    [Parameter(Mandatory = $true)][string]$AuthToken,
    [string]$ProjectId,
    [switch]$AutoProject
  )
  $headers = @{ Authorization = "Bearer $AuthToken" }
  if (-not [string]::IsNullOrWhiteSpace($ProjectId)) {
    $projectName = ''
    $projectResponse = Invoke-AiSmokeJson -Uri "$BackendUrl/api/v1/projects/$ProjectId" -Headers $headers
    if ($projectResponse.Ok) {
      $project = Read-AiSmokeProperty $projectResponse.Payload 'data'
      $projectName = [string](Read-AiSmokeProperty $project 'name')
    }
    $check = Test-AiSmokeProject -BackendUrl $BackendUrl -AuthToken $AuthToken -ProjectId $ProjectId -ProjectName $projectName
    if ($check.Valid) {
      Write-Host "[OK] Selected project: $($check.ProjectName) ($($check.ProjectId))"
    } else {
      Write-Host "[FAIL] Project $ProjectId is not ready for AI smoke run: $($check.Reason)"
    }
    return $check
  }

  if (-not $AutoProject) {
    Write-Host '[INFO] Project selection skipped. Pass -AutoProject or set TEST_PROJECT_ID.'
    return [pscustomobject]@{ Valid = $false; ProjectId = $null; Reason = 'no project selected' }
  }

  $projectsResponse = Invoke-AiSmokeJson -Uri "$BackendUrl/api/v1/projects?access_scope=all&limit=100" -Headers $headers
  if (-not $projectsResponse.Ok) {
    Write-Host "[FAIL] Could not list projects for auto-selection: $($projectsResponse.Error)"
    return [pscustomobject]@{ Valid = $false; ProjectId = $null; Reason = 'project list unavailable' }
  }
  $projects = @(Read-AiSmokeProperty $projectsResponse.Payload 'data')
  if ($projects.Count -eq 0) {
    Write-Host '[FAIL] No projects were returned by the backend.'
    return [pscustomobject]@{ Valid = $false; ProjectId = $null; Reason = 'no projects found' }
  }

  $failures = @()
  foreach ($project in $projects) {
    $candidateId = [string](Read-AiSmokeProperty $project 'id')
    if ([string]::IsNullOrWhiteSpace($candidateId)) {
      continue
    }
    $candidateName = [string](Read-AiSmokeProperty $project 'name')
    $check = Test-AiSmokeProject -BackendUrl $BackendUrl -AuthToken $AuthToken -ProjectId $candidateId -ProjectName $candidateName
    if ($check.Valid) {
      Write-Host "[OK] Auto-selected project: $candidateName ($candidateId)"
      return $check
    }
    $failures += "$candidateName ($candidateId): $($check.Reason)"
  }

  Write-Host '[FAIL] No AI-capable project was found for smoke testing.'
  foreach ($failure in ($failures | Select-Object -First 5)) {
    Write-Host "       $failure"
  }
  return [pscustomobject]@{ Valid = $false; ProjectId = $null; Reason = 'no ready AI project found' }
}
