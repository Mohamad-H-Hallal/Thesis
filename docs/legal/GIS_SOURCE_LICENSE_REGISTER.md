# GIS source, licence and attribution register

Status: delivery policy adopted; final provider accounts, exact source manifests,
live attribution, and redistribution evidence still gate production enablement.

| Source key | Approved intended use | Required controls | Offline/redistribution rule | Release evidence |
|---|---|---|---|---|
| `openstreetmap_standard` | Modest interactive online Street basemap | Visible OpenStreetMap attribution, identifying production User-Agent, provider cache headers, no prefetch/bulk download, monitoring and outage handling | Public tile service is never an offline-package source. OSM-derived output must use a legitimate database extract and satisfy ODbL/attribution obligations. | Engineering controls/tests present; final screen/load review and dated OSM terms record blocked |
| `arcgis_online_hybrid` | Interactive online Hybrid imagery through the TerraLeb server proxy | Operator-owned ArcGIS application, restricted/short-lived credentials, exact dynamic provider attribution, quota/budget/failure metrics, 401/403/429 fallback | No Esri tile is bulk-cached or redistributed offline in v1 | ArcGIS account/terms/credential and measured tile-use evidence blocked |
| `copernicus_sentinel_2_offline` | TerraLeb-generated Lebanon true-colour offline orientation mosaic | Sentinel-2 L2A scene/product IDs, acquisition dates, cloud/shadow filtering, tool/mosaic/reprojection/resampling versions, checksum, 10 m notice and Copernicus attribution | Package may be published only after the exact source/terms/build manifest is approved | Builder/workflow exist; source acquisition, package build, rights and device evidence blocked |
| `osm_derived_offline_labels` | Labels derived from a legitimate Lebanon OSM database extract and combined with the TerraLeb offline package | Extract provider URL/date/checksum, ODbL assessment, derived-database record, attribution, no public tile scraping | Authenticated TerraLeb package only | Geofabrik/approved extract and completed package evidence blocked |
| `sentinel_2_ai` | Approved project imagery input for a protected-super-admin-controlled run | Exact product/source/date/resolution/licence/provenance and project allowlist | Outputs inherit source attribution and redistribution limits | Dataset/project approval and GEE/source evidence blocked |
| `landsat_ai` | Not enabled automatically; usable only after an exact project dataset approval | Exact product/source/date/resolution/licence/provenance and project allowlist | Outputs inherit source attribution and redistribution limits | Not enabled for production without dataset evidence |
| User/project GIS import | Role-gated SHP/GeoJSON/KML/CSV/XLSX import | Uploader records provider/owner, dataset, date, accuracy, authority/licence, attribution, terms and redistribution rules and affirms authority | Decided per source; attestation does not create rights | Fail-closed enforcement may be enabled only after legacy backfill/review and staging tests |

Every production source record must identify provider, dataset/product,
acquisition date/range, version, accuracy/resolution, terms URL, attribution,
online/offline/cache/derived-work/redistribution permissions, reviewer, review
date and immutable evidence. Technical reachability or a free price does not by
itself grant every use right.
