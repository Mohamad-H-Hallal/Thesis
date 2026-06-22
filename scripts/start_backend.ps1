$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
Set-Location (Join-Path $repoRoot 'apps/api')

npm run dev
