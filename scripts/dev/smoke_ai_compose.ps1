param(
  [switch]$Start,
  [switch]$IsolatedPorts,
  [string]$ProjectName = $env:AI_SMOKE_COMPOSE_PROJECT_NAME,
  [string]$BackendUrl = '',
  [string]$AiServerUrl = '',
  [string]$AuthToken = $env:TEST_AUTH_TOKEN,
  [string]$ProjectId = $env:TEST_PROJECT_ID,
  [string]$Email = $env:TEST_EMAIL,
  [string]$Password = $env:TEST_PASSWORD,
  [switch]$AutoAuth,
  [switch]$AutoProject,
  [switch]$StartRun,
  [int]$PollSeconds = 20,
  [switch]$ConfirmDataLoss
)

$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$composeFile = Join-Path $repoRoot 'docker-compose.dev.yml'

$composePrefix = @()
if ($ProjectName) {
  $composePrefix += @('--project-name', $ProjectName)
}

$composeOverride = $null
if ($IsolatedPorts) {
  if (-not $ProjectName) {
    $ProjectName = 'gis_ai_verify'
    $composePrefix = @('--project-name', $ProjectName)
  }
  if (-not $BackendUrl) {
    $BackendUrl = 'http://127.0.0.1:3005'
  }
  if (-not $AiServerUrl) {
    $AiServerUrl = 'http://127.0.0.1:8005'
  }
  $safeProjectName = $ProjectName -replace '[^A-Za-z0-9_.-]', '_'
  $composeOverride = @'
services:
  db:
    ports: !override
      - "55579:5432"
  mailpit:
    ports: !override
      - "1026:1025"
      - "8026:8025"
  api:
    ports: !override
      - "3005:3000"
  ai-server:
    ports: !override
      - "8005:8000"
volumes:
  postgis_data:
    name: "__PROJECT___postgis_data"
  api_node_modules:
    name: "__PROJECT___api_node_modules"
  api_uploads:
    name: "__PROJECT___api_uploads"
  api_exports:
    name: "__PROJECT___api_exports"
  ai_outputs:
    name: "__PROJECT___ai_outputs"
'@
  $composeOverride = $composeOverride.Replace('__PROJECT__', $safeProjectName)
  Write-Host "[WARN] -IsolatedPorts uses Compose project '$ProjectName' and separate volumes such as '${safeProjectName}_postgis_data'."
  Write-Host "[WARN] That isolated database is expected to look empty. Use docker-compose.dev.yml without -IsolatedPorts for the main dev DB volume gis_app_postgis_data."
}

if (-not $BackendUrl) {
  $BackendUrl = 'http://127.0.0.1:3000'
}
if (-not $AiServerUrl) {
  $AiServerUrl = 'http://127.0.0.1:8000'
}

function Invoke-Compose {
  param([Parameter(Mandatory = $true)][string[]]$ComposeArgs)
  $requestsVolumeDelete =
    $ComposeArgs -contains 'down' -and
    (($ComposeArgs -contains '-v') -or ($ComposeArgs -contains '--volumes'))
  $requestsRuntimeReset =
    ($ComposeArgs -join ' ') -match 'reset:runtime|ALLOW_RUNTIME_RESET=true|TRUNCATE|DROP DATABASE|DROP SCHEMA'
  if (($requestsVolumeDelete -or $requestsRuntimeReset) -and -not $ConfirmDataLoss) {
    throw 'Refusing destructive database operation. Re-run with -ConfirmDataLoss only after taking a backup.'
  }
  if ($composeOverride) {
    $composeOverride | docker compose @composePrefix -f $composeFile -f - @ComposeArgs
  } else {
    docker compose @composePrefix -f $composeFile @ComposeArgs
  }
}

function Wait-ForHttp {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [int]$TimeoutSeconds = 120
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    try {
      Invoke-RestMethod -Uri $Url -TimeoutSec 5 | Out-Null
      return $true
    } catch {
      Start-Sleep -Seconds 2
    }
  } while ((Get-Date) -lt $deadline)
  return $false
}

Push-Location $repoRoot
try {
  Invoke-Compose -ComposeArgs @('config', '--quiet')
  Write-Host '[OK] docker-compose.dev.yml config is valid.'

  if ($Start) {
    Invoke-Compose -ComposeArgs @('up', '-d', '--build')
    Write-Host '[OK] Docker Compose dev stack start requested.'
  } else {
    Write-Host '[INFO] Compose stack was not started. Pass -Start to run docker compose up -d --build.'
  }

  Invoke-Compose -ComposeArgs @('ps')

  if ($Start) {
    if (-not (Wait-ForHttp "$AiServerUrl/health")) {
      Write-Host "[FAIL] AI server health did not become ready at $AiServerUrl/health."
      exit 1
    }
    if (-not (Wait-ForHttp "$BackendUrl/health")) {
      Write-Host "[FAIL] Backend health did not become ready at $BackendUrl/health."
      exit 1
    }
  }

  & "$PSScriptRoot\smoke_ai_manual.ps1" `
    -BackendUrl $BackendUrl `
    -AiServerUrl $AiServerUrl `
    -AuthToken $AuthToken `
    -ProjectId $ProjectId `
    -Email $Email `
    -Password $Password `
    -AutoAuth:$AutoAuth `
    -AutoProject:$AutoProject `
    -StartRun:$StartRun `
    -PollSeconds $PollSeconds
} finally {
  Pop-Location
}
