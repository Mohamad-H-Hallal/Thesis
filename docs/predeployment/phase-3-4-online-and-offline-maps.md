# TerraLeb online and offline map production runbook

Last reviewed: 2026-08-26
Release scope: Android and web v1, Lebanon
Authorization status: engineering implemented; provider accounts, exact credentials, live usage measurement and source approval remain blocked on external evidence.

## Current development availability

The development database check on 2026-09-04 found one legacy `lebanon-satellite-v1` Esri row and zero current packages. Migration `0070` deliberately made that legacy bulk-caching source non-current because it has no artifact, provenance, checksum, source approval, or redistribution evidence. The client therefore correctly reports that an offline map has not yet been published; this is not an API outage or lost project data.

The offline screen preserves online maps and drafts, explains the unpublished state, and can check the scoped package provider again. It will enable download automatically after a verified package is published and the existing `offline_map/all` real-time invalidation arrives. Do not reactivate the legacy Esri row or insert placeholder metadata. Actual offline imagery becomes available only after the source-evidence, deterministic build, approval, publication, and device tests below are completed.

## Architecture

- Street view remains normal, interactive OpenStreetMap raster use. The URL is configurable, attribution remains visible, and no offline package is generated from the public OSM tile service.
- Hybrid view remains available. Production and staging use TerraLeb's authenticated API proxy, which obtains an ArcGIS token from server-side credentials, applies shared quotas and rate limits, validates upstream responses, and returns only bounded Lebanon tiles.
- If ArcGIS is unavailable, unauthorized, rate-limited or over its configured quota, the app retains overlays, drawing, map camera and unsaved forms and falls back to Street with a short notice.
- A protected-super-administrator switch can disable the Hybrid provider without an app release. Changes use the existing scoped real-time settings event.
- Offline Hybrid uses a TerraLeb-owned ZIP artifact built from reviewed Copernicus Sentinel-2 true-colour imagery plus labels rendered from a legitimate OSM data extract. It never scrapes OSM or Esri online tiles.

The OSM Foundation tile policy permits normal interactive viewing but requires visible attribution, identifiable requests and cache compliance, and prohibits bulk/offline downloads from `tile.openstreetmap.org`: <https://operations.osmfoundation.org/policies/tiles/>. ArcGIS requires an account/authentication, provider attribution, and a reviewed tile or session usage model: <https://developers.arcgis.com/rest/basemap-styles/>. Copernicus Sentinel data is free, full and open for lawful reuse, with source notices required for distribution and modified products: <https://sentinels.copernicus.eu/documents/247904/690755/Sentinel_Data_Legal_Notice>.

## Development commands

The existing emulator command is unchanged and retains the development-only direct provider behavior:

```powershell
flutter run -d emulator-5554 --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL=http://10.0.2.2:3000
```

To exercise the production-style authenticated map proxy in development after ArcGIS credentials are supplied to the backend:

```powershell
flutter run -d emulator-5554 --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL=http://10.0.2.2:3000 --dart-define=MAP_HYBRID_USE_API_PROXY=true
```

No provider token belongs in a Flutter define, source file, Git, log or chat.

## Build a provider-neutral offline package

Prerequisites are actual downloaded Sentinel-2 source products, a legitimate OSM extract, reviewed terms evidence and a reproducible rendering pipeline. The repository does not fabricate these inputs.

1. Copy `infra/offline-map/package-manifest.example.json` outside the repository or to a reviewed evidence workspace.
2. Replace every placeholder with the immutable package version, exact Sentinel scene IDs and acquisition dates, reviewed terms URLs, required attribution, cloud/shadow rules, mosaic/clipping/reprojection/resampling methods, exact tool versions, and OSM extract provider/date/SHA-256/terms.
3. Render tiles into `tiles/{z}/{x}/{y}.tile`. A tile may contain PNG, JPEG or WebP bytes; only tiles within the declared Lebanon zoom range are accepted.
4. Build the deterministic package:

```powershell
python infra/offline-map/build_package.py --tiles D:\reviewed-input\tiles --manifest D:\reviewed-input\manifest.json --output D:\reviewed-output\terraleb-lebanon-v1.zip
```

5. Retain the command output, manifest, input checksums, tool/container digests and terms snapshots as immutable source evidence.
6. Populate the `data_source_license` approval fields only after the designated GIS/legal owner approves offline use, adaptation and redistribution. Do not bypass the database gate.
7. Publish as the protected super administrator:

```powershell
cd apps\api
npm run offline-map:publish -- --package D:\reviewed-output\terraleb-lebanon-v1.zip --manifest D:\reviewed-input\manifest.json --actor-user-id REPLACE_WITH_PROTECTED_SUPER_ADMIN_UUID
```

The publisher verifies the bounded embedded manifest against the supplied manifest, hashes the package, writes it to private object storage, enforces immutable versions, records provenance, atomically switches the current package and publishes one scoped invalidation.

## Verification

- Run `python -m unittest infra/offline-map/test_build_package.py -v`.
- Run the backend `offlineMapPackage` and storage tests.
- Run Flutter offline package, license and project download tests.
- On two contributor sessions, download, interrupt/resume, enter airplane mode, reopen the same project, pan/zoom/draw/edit a draft, replace the package and verify no draft or camera loss.
- With ArcGIS credentials configured, measure returned tile counts for each important screen and normal session. Compare actual monthly projections against the configured daily limit before choosing a different billing model.

## Rollback

- Disable Hybrid through Support Settings; clients receive the scoped settings update and fall back to Street.
- Keep provider credentials mounted but revoke them in ArcGIS if compromised; never publish them to the client.
- Keep the last known-good immutable offline object and database record. Publish a reviewed replacement version; never mutate an existing version.
- Rolling back application containers does not delete private artifacts. Object cleanup follows the separate retention/reconciliation process.

## Remaining external evidence

- ArcGIS organization/application, credential restriction method, exact terms/attribution response, budget and quota alerts, and live tile measurements.
- Exact Sentinel scenes and dates, source-product checksums and terms snapshot.
- Exact OSM extract provider, extract checksum/terms and the label-rendering toolchain.
- Signed approval for offline adaptation/redistribution and final on-screen/export attribution.
