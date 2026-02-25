param(
  [string]$BaseUrl = "http://localhost",
  [switch]$SkipUp,
  [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
Set-Location $repoRoot

if (-not $SkipUp) {
  docker compose -f docker-compose.yml up -d --build
}

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$healthy = $false
while ((Get-Date) -lt $deadline) {
  try {
    $health = Invoke-RestMethod -Uri "$BaseUrl/health" -Method Get -TimeoutSec 5
    if ($health.status -eq 'live') {
      $healthy = $true
      break
    }
  } catch {
    Start-Sleep -Seconds 3
  }
}

if (-not $healthy) {
  throw "Health endpoint did not become ready within $TimeoutSeconds seconds"
}

Invoke-WebRequest -Uri "$BaseUrl/api/v1" -Method Get -UseBasicParsing | Out-Null
Invoke-WebRequest -Uri "$BaseUrl/docs/openapi.yaml" -Method Get -UseBasicParsing | Out-Null

$email = "smoke.$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())@example.com"
$password = 'SmokeTest!123'

$adminAttemptPayload = @{
  email = $email
  password = $password
  full_name = 'Smoke User Admin Attempt'
  role = 'admin'
} | ConvertTo-Json

$adminAttemptBlocked = $false
try {
  Invoke-RestMethod -Uri "$BaseUrl/api/v1/auth/register" -Method Post -ContentType 'application/json' -Body $adminAttemptPayload | Out-Null
} catch {
  $statusCode = $_.Exception.Response.StatusCode.value__
  if ($statusCode -eq 400) {
    $adminAttemptBlocked = $true
  } else {
    throw
  }
}

if (-not $adminAttemptBlocked) {
  throw 'Public register admin attempt was not blocked'
}

$registerPayload = @{
  email = $email
  password = $password
  full_name = 'Smoke User'
} | ConvertTo-Json

$registerResponse = Invoke-RestMethod -Uri "$BaseUrl/api/v1/auth/register" -Method Post -ContentType 'application/json' -Body $registerPayload
if ($registerResponse.data.user.role -ne 'contributor') {
  throw "Expected contributor role from public signup, got '$($registerResponse.data.user.role)'"
}

$loginPayload = @{
  email = $email
  password = $password
} | ConvertTo-Json

$loginResponse = Invoke-RestMethod -Uri "$BaseUrl/api/v1/auth/login" -Method Post -ContentType 'application/json' -Body $loginPayload
$token = $loginResponse.data.token
if (-not $token) {
  throw 'Login token missing from response'
}

Invoke-RestMethod -Uri "$BaseUrl/api/v1/auth/me" -Method Get -Headers @{ Authorization = "Bearer $token" } | Out-Null

Write-Host "Smoke test passed against $BaseUrl"
