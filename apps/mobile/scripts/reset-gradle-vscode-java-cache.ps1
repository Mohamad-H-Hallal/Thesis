param(
  [switch]$KillJavaProcesses
)

$ErrorActionPreference = "Stop"

$repoMobile = Split-Path -Parent $PSScriptRoot
$androidDir = Join-Path $repoMobile "android"
$gradlewBat = Join-Path $androidDir "gradlew.bat"
$userGradle = Join-Path $env:USERPROFILE ".gradle"
$globalStorage = Join-Path $env:APPDATA "Code\User\globalStorage\redhat.java"

Write-Host "== Reset Gradle + VS Code Java caches ==" -ForegroundColor Cyan
Write-Host "Mobile dir: $repoMobile"
Write-Host "Android dir: $androidDir"

if (Test-Path $gradlewBat) {
  Write-Host "[1/5] Stopping Gradle daemons..." -ForegroundColor Yellow
  Push-Location $androidDir
  try {
    & $gradlewBat --stop | Out-Host
  } finally {
    Pop-Location
  }
}

if ($KillJavaProcesses) {
  Write-Host "[2/5] Killing Gradle/JDTLS Java processes..." -ForegroundColor Yellow
  $javaProcs = Get-CimInstance Win32_Process |
    Where-Object {
      ($_.Name -ieq "java.exe" -or $_.Name -ieq "javaw.exe") -and
      ($_.CommandLine -match "GradleDaemon|org\.eclipse\.jdt\.ls")
    }
  foreach ($proc in $javaProcs) {
    try {
      Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
      Write-Host "Stopped PID $($proc.ProcessId)"
    } catch {
      Write-Warning "Could not stop PID $($proc.ProcessId): $($_.Exception.Message)"
    }
  }
}

Write-Host "[3/5] Removing android/.gradle..." -ForegroundColor Yellow
$androidGradle = Join-Path $androidDir ".gradle"
if (Test-Path $androidGradle) {
  Remove-Item $androidGradle -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "[4/5] Removing user Gradle caches + daemon..." -ForegroundColor Yellow
$userCaches = Join-Path $userGradle "caches"
$userDaemon = Join-Path $userGradle "daemon"
if (Test-Path $userCaches) {
  Remove-Item $userCaches -Recurse -Force -ErrorAction SilentlyContinue
}
if (Test-Path $userDaemon) {
  Remove-Item $userDaemon -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "[5/5] Removing RedHat Java LS runtime cache..." -ForegroundColor Yellow
if (Test-Path $globalStorage) {
  Get-ChildItem $globalStorage -Directory | ForEach-Object {
    $configWin = Join-Path $_.FullName "config_win"
    $configSsWin = Join-Path $_.FullName "config_ss_win"
    if (Test-Path $configWin) {
      Remove-Item $configWin -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $configSsWin) {
      Remove-Item $configSsWin -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "Next steps:"
Write-Host "1) Fully close VS Code."
Write-Host "2) Reopen workspace."
Write-Host "3) Run: Java: Clean Java Language Server Workspace"
Write-Host "4) Verify: cd apps/mobile/android; .\gradlew -v"
