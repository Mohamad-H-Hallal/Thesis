$ErrorActionPreference = 'Stop'

function Quote-PwshLiteral {
  param([Parameter(Mandatory = $true)][string]$Value)
  return "'" + $Value.Replace("'", "''") + "'"
}

function Read-DotEnv {
  param([Parameter(Mandatory = $true)][string]$Path)
  $values = @{}
  if (-not (Test-Path -LiteralPath $Path)) {
    return $values
  }
  foreach ($line in Get-Content -LiteralPath $Path) {
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
  return $values
}

function Get-EnvValue {
  param(
    [Parameter(Mandatory = $true)][hashtable]$Values,
    [Parameter(Mandatory = $true)][string[]]$Names,
    [Parameter(Mandatory = $true)][string]$Fallback
  )
  foreach ($name in $Names) {
    if ($Values.ContainsKey($name) -and -not [string]::IsNullOrWhiteSpace($Values[$name])) {
      return $Values[$name]
    }
  }
  return $Fallback
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$apiRoot = Join-Path $repoRoot 'apps\api'
$aiRepo = Resolve-Path (Join-Path $repoRoot '..\AI-ML-pipeline-for-AI-Enhanced-Mobile-GIS')
$aiStartScript = Join-Path $aiRepo 'scripts\start_ai_server.ps1'
$appEnv = Read-DotEnv -Path (Join-Path $repoRoot '.env')

if (-not (Test-Path $aiStartScript)) {
  throw "AI server start script was not found at $aiStartScript"
}

$backendUrl = 'http://127.0.0.1:3000'
$aiServerUrl = 'http://127.0.0.1:8000'
$callbackSecret = 'dev-ai-callback-secret-change-me'
$dbName = Get-EnvValue -Values $appEnv -Names @('DB_NAME', 'POSTGRES_DB') -Fallback 'gis_app'
$dbUser = Get-EnvValue -Values $appEnv -Names @('DB_USER', 'POSTGRES_USER') -Fallback 'gis_user'
$dbPassword = Get-EnvValue -Values $appEnv -Names @('DB_PASSWORD', 'POSTGRES_PASSWORD') -Fallback 'change_me'
$configuredDbHost = Get-EnvValue -Values $appEnv -Names @('DB_HOST') -Fallback '127.0.0.1'
$hostDbHost = if ($configuredDbHost -in @('127.0.0.1', 'localhost')) { $configuredDbHost } else { '127.0.0.1' }
$hostDbPort = if ($configuredDbHost -eq 'db') {
  Get-EnvValue -Values $appEnv -Names @('POSTGRES_HOST_PORT') -Fallback '55578'
} else {
  Get-EnvValue -Values $appEnv -Names @('DB_PORT', 'POSTGRES_HOST_PORT') -Fallback '5432'
}
$databaseUrl = 'postgresql://{0}:{1}@{2}:{3}/{4}' -f `
  [Uri]::EscapeDataString($dbUser),
  [Uri]::EscapeDataString($dbPassword),
  $hostDbHost,
  $hostDbPort,
  [Uri]::EscapeDataString($dbName)

$backendCommand = @(
  "`$env:AI_SERVER_URL='$aiServerUrl'"
  "`$env:AI_CALLBACK_BASE_URL='$backendUrl'"
  "`$env:APP_PUBLIC_API_URL='$backendUrl'"
  "`$env:AI_CALLBACK_SECRET='$callbackSecret'"
  "`$env:AI_SERVER_TIMEOUT_MS='30000'"
  'Write-Host "Starting backend API on http://127.0.0.1:3000"'
  "Set-Location -LiteralPath $(Quote-PwshLiteral $apiRoot)"
  'npm run dev'
) -join '; '

$aiCommand = @(
  "`$env:AI_DRY_RUN='false'"
  "`$env:DATABASE_URL=$(Quote-PwshLiteral $databaseUrl)"
  "`$env:APP_BACKEND_URL='$backendUrl'"
  "`$env:AI_CALLBACK_SECRET='$callbackSecret'"
  "`$env:OUTPUTS_DIR='outputs'"
  'Write-Host "Starting Python AI server on http://127.0.0.1:8000 in real mode"'
  "Set-Location -LiteralPath $(Quote-PwshLiteral $aiRepo)"
  ".\scripts\start_ai_server.ps1"
) -join '; '

Start-Process -FilePath 'powershell.exe' -WindowStyle Normal -ArgumentList @(
  '-NoExit',
  '-ExecutionPolicy',
  'Bypass',
  '-Command',
  $backendCommand
)

Start-Process -FilePath 'powershell.exe' -WindowStyle Normal -ArgumentList @(
  '-NoExit',
  '-ExecutionPolicy',
  'Bypass',
  '-Command',
  $aiCommand
)

Write-Host 'Development AI stack launch requested.'
Write-Host 'Backend:   http://127.0.0.1:3000'
Write-Host 'AI server: http://127.0.0.1:8000'
Write-Host 'AI mode:   real (AI_DRY_RUN=false)'
Write-Host 'Run Flutter separately. Flutter talks to the backend only; it never starts Python.'
Write-Host 'No secrets were printed. Database and callback credentials were injected into child processes.'
