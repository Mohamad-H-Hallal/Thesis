# GIS source, license and attribution register

| Source key | Current endpoint/use | Known technical requirement | Offline/redistribution status | Release status |
|---|---|---|---|---|
| `openstreetmap_standard` | `tile.openstreetmap.org` street basemap | Visible OpenStreetMap attribution, identifiable client, caching and public-tile usage policy | Public tile bulk/offline download is not allowed; database/content licensing must be assessed for derived exports | Online only after attribution/client verification; offline prohibited |
| `esri_world_imagery` | ArcGIS World Imagery tiles | Esri/source attribution and applicable service terms | No TerraLeb entitlement evidence for bulk Lebanon offline package or redistribution | BLOCKING for offline; contract review required for production online use |
| `esri_reference_labels` | ArcGIS World Boundaries and Places overlay | Esri/source attribution and service terms | Must follow the licensed basemap use | BLOCKING pending same review |
| `sentinel_2` | AI configuration/provenance references | Dataset terms, provider attribution, processing provenance | DECISION REQUIRED for output redistribution/training | Register exact source/product/version before real run |
| `landsat` | AI configuration/provenance references | Dataset terms, provider attribution, processing provenance | DECISION REQUIRED | Register exact source/product/version before real run |
| User/project GIS import | Uploaded SHP/GeoJSON/KML/CSV/XLSX | The upload UI records provider/owner, dataset, date, accuracy, authority/license, attribution, terms and redistribution rules with an affirmative uploader attestation | Determined per import/source; attestation is not legal approval | Approval can be fail-closed with `IMPORT_PROVENANCE_ENFORCEMENT_ENABLED=true`; provenance is carried into approved features and exports |

Every production source requires provider, dataset/product, acquisition date or
range, version, accuracy/resolution, license/terms URL, attribution text,
online/offline/cache/derived-work/redistribution permissions, review date and
approval evidence. A URL's technical accessibility is not a license.

Production approval requires the provenance enforcement flag, review of legacy
imports whose provenance is empty, and evidence that every enabled map/offline
source has the corresponding approved right in `data_source_license`.
