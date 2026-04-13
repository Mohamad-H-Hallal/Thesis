# Exports and Reporting Guide

## Request an Export
1. Open project details or exports dashboard.
2. Select the project and export format.
3. Leave the filters blank to export the full approved dataset, or apply filters when you need a smaller package.
4. Status moves through pending -> processing -> completed/failed.

### Export Formats
- `GeoJSON`: best for `QGIS`, `geojson.io`, `mapshaper.org`, and web-map QA.
- `Shapefile`: best for desktop GIS workflows that expect a zipped shapefile package.

### Optional Filters
- `From date`: `YYYY-MM-DD`
  - Example: `2026-04-13`
  - Includes approved features collected on or after that date.
- `To date`: `YYYY-MM-DD`
  - Example: `2026-04-30`
  - Includes approved features collected up to that day.
- `BBOX`: `minLon,minLat,maxLon,maxLat`
  - Example: `35.44,33.84,35.58,33.94`
  - Includes only approved features inside that rectangle.

If all filters are blank, the export contains all approved features for the selected project.

## Track Export Jobs
- Use exports dashboard list.
- Check status and timestamps.
- Retry failed exports after root cause is resolved.
- Each job now shows whether it was filtered by date or area.

## Download Export
1. Open completed job.
2. Tap download action.
3. Use `Open`, `Share`, or `Copy path` from the completed job card.

### Android Save Location
Downloaded files are stored under:

`/storage/emulated/0/Android/data/com.example.lebanese_gis_mobile/files/exports/`

Many Android file browsers hide `Android/data`. On an emulator or connected device, use:

```powershell
adb pull "/storage/emulated/0/Android/data/com.example.lebanese_gis_mobile/files/exports" D:\GIS_APP\exports_from_device
```

You can also use `scripts/inspect-export-package.ps1` to inspect a downloaded ZIP locally.

## Validate an Export Package

### GeoJSON
1. Unzip the package.
2. Open the `.geojson` file in `QGIS`, `geojson.io`, or `mapshaper.org`.
3. Confirm:
   - only approved features are present
   - geometry count matches the approved-review count
   - attributes and coordinates are correct

### Shapefile
1. Unzip the package.
2. Keep these files together:
   - `.shp`
   - `.shx`
   - `.dbf`
   - `.prj`
3. Open the `.shp` file in `QGIS`.
4. Confirm:
   - geometry count matches the approved-review count
   - coordinates plot correctly over an OSM basemap
   - attribute table matches approved review data

### OSM / placement check
- For geometry placement against OSM, use `QGIS` with an OSM basemap or import the GeoJSON into `JOSM`.
- Compare exported points or polygons against roads, settlements, and known landmarks before any downstream OSM workflow.

## Reporting
- Basic dashboards summarize project and review progress.
- For official reports, use approved export files and audit trail references.
