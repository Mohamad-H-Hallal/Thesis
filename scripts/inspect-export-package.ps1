param(
    [Parameter(Mandatory = $true)]
    [string]$ZipPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ZipPath)) {
    throw "ZIP file not found: $ZipPath"
}

$resolvedZip = (Resolve-Path -LiteralPath $ZipPath).Path
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("export_inspect_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot | Out-Null

try {
    Expand-Archive -LiteralPath $resolvedZip -DestinationPath $tempRoot -Force

    $files = Get-ChildItem -Path $tempRoot -File -Recurse | Sort-Object FullName
    Write-Host "Archive:" $resolvedZip
    Write-Host "Entries:"
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($tempRoot.Length + 1)
        Write-Host " - $relative ($($file.Length) bytes)"
    }

    $metadataPath = Join-Path $tempRoot 'metadata.json'
    if (Test-Path -LiteralPath $metadataPath) {
        Write-Host ""
        Write-Host "Metadata:"
        $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
        $metadata | ConvertTo-Json -Depth 6
    }

    $geojsonFile = Get-ChildItem -Path $tempRoot -Filter *.geojson -File -Recurse | Select-Object -First 1
    if ($null -ne $geojsonFile) {
        Write-Host ""
        Write-Host "GeoJSON summary:"
        $geojson = Get-Content -LiteralPath $geojsonFile.FullName -Raw | ConvertFrom-Json
        $features = @($geojson.features)
        $geometryTypes = $features |
            ForEach-Object { $_.geometry.type } |
            Sort-Object -Unique

        Write-Host " - Feature count:" $features.Count
        Write-Host " - Geometry types:" ($geometryTypes -join ', ')
        if ($features.Count -gt 0) {
            $bounds = @{
                minLon = [double]::PositiveInfinity
                minLat = [double]::PositiveInfinity
                maxLon = [double]::NegativeInfinity
                maxLat = [double]::NegativeInfinity
            }
            foreach ($feature in $features) {
                $coordinates = $feature.geometry.coordinates
                if ($feature.geometry.type -eq 'Point' -and $coordinates.Count -ge 2) {
                    $lon = [double]$coordinates[0]
                    $lat = [double]$coordinates[1]
                    if ($lon -lt $bounds.minLon) { $bounds.minLon = $lon }
                    if ($lon -gt $bounds.maxLon) { $bounds.maxLon = $lon }
                    if ($lat -lt $bounds.minLat) { $bounds.minLat = $lat }
                    if ($lat -gt $bounds.maxLat) { $bounds.maxLat = $lat }
                }
            }
            if (
                $bounds.minLon -ne [double]::PositiveInfinity -and
                $bounds.minLat -ne [double]::PositiveInfinity -and
                $bounds.maxLon -ne [double]::NegativeInfinity -and
                $bounds.maxLat -ne [double]::NegativeInfinity
            ) {
                Write-Host " - Point bounds: $($bounds.minLon),$($bounds.minLat) -> $($bounds.maxLon),$($bounds.maxLat)"
            }
        }
    }

    $shapefileBase = Get-ChildItem -Path $tempRoot -Filter *.shp -File -Recurse | Select-Object -First 1
    if ($null -ne $shapefileBase) {
        Write-Host ""
        Write-Host "Shapefile package:"
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($shapefileBase.Name)
        $folder = $shapefileBase.DirectoryName
        $requiredExtensions = '.shp', '.shx', '.dbf', '.prj'
        foreach ($extension in $requiredExtensions) {
            $candidate = Join-Path $folder ($baseName + $extension)
            $exists = Test-Path -LiteralPath $candidate
            Write-Host " - $baseName$extension : $exists"
        }
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
