# TerraLeb map and regional-hosting decision

Status: **owner decision and engineering execution plan - not production approval**

Prepared: **2026-08-19**

Currency: **USD; taxes, exchange charges, labour and counsel excluded**

## 1. Final decision

TerraLeb will preserve its current user workflow:

- **Street** remains an online OpenStreetMap view.
- **Hybrid** remains satellite imagery with reference labels.
- contributors can continue viewing Lebanon and drawing project geometry on
  either view when connected;
- the existing offline-project map option remains;
- no map button or GIS collection capability is removed.

No map subscription has to be purchased for the initial release if TerraLeb
uses the sources below within their free/open terms. “Licensed” does not always
mean “paid”: OpenStreetMap and Copernicus grant open rights subject to conditions,
and ArcGIS Location Platform provides a usage-limited free tier under its terms.

The selected initial source design is:

| App mode | Production source | Initial purchase | Conditions |
|---|---|---:|---|
| Street online | OSM Standard raster tiles | $0 | Interactive viewing only; visible attribution, identifying client, HTTP caching, no bulk/offline download and no SLA. |
| Hybrid online | Supported ArcGIS Location Platform/Online imagery and reference services | $0 while within the free allowance | Operator-owned account, restricted app credential/session, attribution, quota/budget monitoring and accepted terms. |
| Hybrid offline | TerraLeb-produced Lebanon package using Copernicus Sentinel-2 true-colour imagery plus OSM-derived reference labels | $0 data purchase | Record source/date/processing/terms; display attribution; host the package on TerraLeb storage; never scrape OSM or Esri public tile servers. |

If TerraLeb later needs the same high-resolution commercial imagery offline, it
must use institution-owned orthophotos or purchase terms that expressly permit
offline mobile redistribution. That is an optional quality upgrade, not a launch
requirement under the selected open-data design.

## 2. What the application actually does today

Repository inspection shows:

- `LebanonBasemapStyle.street` calls
  `https://tile.openstreetmap.org/{z}/{x}/{y}.png`;
- the UI label **Hybrid** maps to `LebanonBasemapStyle.satellite`;
- Hybrid calls Esri `World_Imagery` and overlays Esri
  `World_Boundaries_and_Places` labels;
- the offline cache already rejects OSM Street bulk download;
- the project offline workflow attempts Satellite/Hybrid caching only when
  `LICENSED_ESRI_OFFLINE_BASEMAP_ENABLED` is enabled;
- therefore OSM is **Street**, not Hybrid, and the current legal/operational gap
  is full-area caching from the Esri imagery endpoint.

## 3. Why OSM can remain free

OpenStreetMap data is open under the ODbL. The community-operated Standard tile
server is a separate, donation-funded service. It permits normal interactive
viewing without a purchase, but requires:

- visible `© OpenStreetMap contributors` attribution that is not covered by the
  drawer or other UI;
- a stable TerraLeb User-Agent/app identifier and a public contact;
- correct web Referer behavior;
- honoring cache headers, or at least seven-day caching where headers cannot be
  honored;
- no prefetch, country/city download, scraping or offline archive generation;
- an operational fallback because the service has no SLA and may block heavy or
  nonconforming traffic.

TerraLeb's intended online use - humans viewing Lebanon and drawing geometry in
the active viewport - is within the normal interactive pattern if the technical
requirements above are implemented. The source should be configurable so a
paid or self-hosted OSM-derived provider can be introduced later without an app
redesign if usage grows.

## 4. Why online ArcGIS can remain free initially

The public reachability of the legacy World Imagery URL is not itself a promise
of unlimited anonymous production use. TerraLeb should move to the supported
ArcGIS Location Platform/Online access model:

- create an operator-owned account/application;
- use a restricted API key or supported session/token flow;
- keep Esri and underlying imagery-provider attribution visible;
- monitor quotas and reject accidental runaway usage;
- do not send TerraLeb project geometries to ArcGIS merely to request basemap
  tiles; ordinary tile requests expose the viewed tile area, IP and request
  metadata;
- fetch only tiles needed for the current viewport.

ArcGIS currently publishes an allowance of two million static basemap tiles,
then $0.15 per 1,000 tiles. TerraLeb can start at $0 and configure alerts before
70%, 90% and 100% of the free allowance. The application must degrade safely to
Street or a clear provider-unavailable state when the cap is reached; it must
not create an uncontrolled bill.

## 5. Free offline Hybrid design

Directly downloading the Esri World Imagery tile pyramid for Lebanon into a
custom Flutter cache is not covered merely because the online URL responds.
Esri documents specific export/offline workflows, accounts, product limits and
content-specific terms; some exported World Imagery packages are restricted to
ArcGIS use. TerraLeb will not rely on that path for its free initial release.

Instead, create a versioned package containing:

1. a recent low-cloud Lebanon true-colour mosaic from
   `COPERNICUS/S2_SR_HARMONIZED` or the equivalent Copernicus Data Space source;
2. source scene IDs, acquisition range, cloud mask/composite method, processing
   date, checksum and exact Copernicus terms reference;
3. OSM-derived place/road/boundary labels generated from a dated Lebanon
   extract, with ODbL attribution and derived-database assessment;
4. package bounds, supported zoom range, native resolution, tile count, size,
   version and expiry/replacement policy;
5. authenticated resumable download, checksum verification, account isolation
   and safe replacement in the existing offline storage workflow.

Sentinel-2 true-colour bands have 10 m pixels. The offline view must therefore
say it is an orientation basemap and show its imagery date/resolution. It must
not claim parcel, cadastral, survey or high-resolution orthophoto accuracy.
Contributors may still collect GPS geometry and draw approximate project
geometry. If a project needs building/parcel-grade interpretation, it must
provide authorized higher-resolution imagery or require online Hybrid.

This is the only necessary user-visible map difference: offline Hybrid has an
open Sentinel-2 source and an explicit accuracy/date notice instead of silently
copying Esri imagery. The controls and collection workflow remain intact.

## 6. Regional hosting decision and costs

The inspected production and observability Compose limits total about 13.7 GB
before the operating system, Docker overhead, migration headroom and the Python
AI service. A 16 GB production host is unsafe; use 32 GB.

### Recommended regional initial host: Oracle Cloud Jeddah

OCI operates live regions in Jeddah, Riyadh, Dubai and Abu Dhabi and publishes
consistent public-region pricing. Start with **Saudi Arabia West (Jeddah)**,
subject to a real latency test from Lebanese mobile networks and capacity in the
operator's tenancy.

| Item | Calculation | Estimated monthly |
|---|---|---:|
| OCI Ampere A1 Flex compute | 4 OCPU × $0.013106/h plus 32 GB × $0.0019659/GB-h, 730 h | $84.19 |
| Balanced 320 GB block volume | planning rate around $0.0255/GB-month | about $8–15 |
| Private object storage and incremental backups | small fresh deployment | about $5–20 |
| DNS, email, monitoring and public-network allowance | mostly free/low-volume tiers | about $0–15 |
| Domain amortization | final TLD/registrar dependent | about $1–5 |
| **Expected regional total** | before GEE and tax | **about $100–140/month** |

OCI includes the first 10 TB/month of outbound internet data in its published
allowance. Do not design around a promotional free VM: create a paid operator
tenancy, budgets and hard alerts so production is not dependent on free-tier
capacity.

The A1 shape is ARM64. Before choosing it, every TerraLeb image - PostGIS,
ClamAV, Valkey, Node API/worker, Nginx, Prometheus/Loki/Alloy and the Python/GDAL
AI stack - must build and pass its production tests on ARM64. If any dependency is
not reliable:

- use OCI `VM.Standard.E4.Flex`, 4 OCPU/32 GB in Jeddah: compute is about
  $141.60/month and the expected complete single-host total is about
  **$160–200/month**; or
- use the previously costed Hetzner 32 GB x86 option at about **$53–84/month**
  if Middle East hosting is no longer mandatory.

For sustained CPU load, an A1 6 OCPU/32 GB shape costs about $103.33/month for
compute and approximately **$120–160/month** complete. Resize only from measured
CPU, queue and latency evidence.

### Why DigitalOcean is not selected

DigitalOcean is a reputable and simple platform, but its current region list has
Frankfurt and Bangalore - not a Middle East region. Its published dedicated
32 GB options begin around $168/month for 4 vCPU memory-optimized or $252/month
for 8 vCPU general purpose, before 20–30% backups, additional storage, Spaces,
domain and ancillary services. It is therefore neither more regional nor less
expensive than the selected OCI or Hetzner designs for TerraLeb.

### Availability limitation

A single OCI Jeddah VM is not high availability, just as the proposed single
Hetzner or single-EC2 host is not HA. The initial design must include daily
encrypted off-host backups, a proven restore, immutable release artifacts and a
replacement-server runbook. Split the database/API/workers across failure
domains only after measured need or an institutional availability requirement.

## 7. Phase 0–8 execution plan

### Phase 0 - audit and baseline

- preserve all existing worktree changes;
- read repository guidance and inventory map, AI, privacy, deletion, deployment
  and legal readiness work;
- record migration head/checksums, Flutter/backend/Docker baseline and current
  API/database/memory/CPU behavior;
- produce a dependency/ARM64 compatibility matrix.

Exit: no unknown conflicting change and reproducible baseline.

### Phase 1 - decisions, configuration and release gates

- record this source/hosting decision in the legal and GIS registers;
- make map URLs, app identifier, attribution, quota and offline-package source
  configurable;
- add OCI provider/region, ARM architecture and secrets validation;
- represent approved, blocked and not-in-release-scope evidence honestly;
- keep production fail-closed for placeholders, demo hosts, test seeds or
  unresolved mandatory evidence.

Exit: environment/release-gate tests pass; no readiness boolean is invented.

### Phase 2 - online map provider correction

- retain Street/Hybrid toggles and map camera/drawing behavior;
- use the final TerraLeb package ID/User-Agent for OSM;
- verify caching, Referer and visible attribution on every map;
- replace anonymous legacy Esri URLs with supported credentialed services;
- implement token/session expiry, quota/budget state, safe Street fallback and
  provider metrics without geometry/PII logs.

Exit: online Street and Hybrid work under provider terms with no purchase at
initial usage and no workflow regression.

### Phase 3 - free offline Hybrid package

- add a reproducible Sentinel-2 mosaic/package build pipeline;
- add OSM-derived offline reference labels;
- extend package metadata for source/date/resolution/terms/checksum;
- reuse the existing authenticated download, local isolation and progress UX;
- remove any code path that bulk-fetches public OSM or Esri tile pyramids;
- preserve offline forms, drafts, GPS and synchronization.

Exit: airplane-mode Hybrid works from a verified package and clearly identifies
its source, age and 10 m limitation.

### Phase 4 - OCI production architecture

- add an OCI deployment overlay/IaC for a private network, firewall, VM, object
  storage, backup policy, DNS and budgets without storing secrets in Git;
- build and test the full stack on ARM64; automatically select x86 E4 only when
  the recorded compatibility gate fails;
- expose only 80/443 and restricted SSH/VPN access;
- keep database, Valkey, ClamAV, AI and observability private;
- prove TLS renewal, restart, disk-full handling, backup and isolated restore.

Exit: staging deployment and restore evidence; estimated versus actual cost.

### Phase 5 - AI and deletion policy completion

- deploy AI at environment level while every project defaults off;
- keep enable/run/validate/publish protected-super-admin only;
- allow only approved project GIS/dataset inputs and no account/session/private
  draft fields;
- on approved account deletion retain accepted GIS/minimal final provenance and
  delete drafts, pending/unapproved content and direct identifiers;
- preserve automatic responsibility release, tombstone/masked-label and idempotent worker
  rules.

Exit: authorization, no-PII AI payload and deletion integrity tests pass.

### Phase 6 - clean production bootstrap and complete workflows

- migrate an empty production database;
- create only the protected super-admin from secrets;
- prohibit staging/test seeds and fake acceptances in production;
- complete privacy request, correction, export, moderation and deletion
  execution without bypassing fail-closed safeguards;
- publish scoped real-time events and no polling.

Exit: complete backend/Flutter workflow and clean-bootstrap tests.

### Phase 7 - production verification and evidence

- run backend formatting, lint, typecheck, unit, integration, security,
  migration, Docker, WebSocket and performance suites;
- run Flutter formatting, analysis, unit/widget/integration tests and supported
  Android/web builds;
- test real Lebanon networks/devices, OSM/ArcGIS quotas, offline package,
  AI run, deletion, privacy export, notifications, restore and rollback;
- verify p50/p95, query volume, memory, cost and no >5% unjustified regression;
- generate an exact remaining-manual-action report with screenshots/evidence
  references but no secrets.

Exit: every engineering gate is proven; external owner/counsel/provider facts
remain visibly blocked until actually supplied.

### Phase 8 - external approval and release

- owner supplies exact operator/address/privacy contact/domain and creates OCI,
  ArcGIS, GEE, Firebase/Play and email accounts;
- counsel approves exact Arabic/English document hashes and retention/basis;
- Play disclosures are completed against the signed AAB;
- named owner reviews staging, evidence, costs and rollback, then explicitly
  authorizes the exact build.

Phase 8 cannot be completed by code alone. Codex must never fabricate an account,
contract, counsel opinion, store approval, provider credential or test result.

## 8. Remaining manual choices and actions

The engineering direction is settled. The following real-world acts remain:

1. Approve OCI Jeddah A1 as the first regional target and OCI E4 x86 as its
   compatibility fallback.
2. Create the paid operator OCI tenancy, ArcGIS application and GEE billing or
   approved-eligibility project.
3. Supply the real legal operator, address, privacy contact and controlled domain.
4. Decide whether the 10 m offline Sentinel-2 quality is sufficient for each
   project; supply institution-owned higher-resolution imagery when it is not.
5. Provide final Arabic/English policies to Lebanese counsel and record approval.
6. Complete Google Play organization/testing/disclosure steps.
7. Run and sign the production-like pilot and restore/rollback drills.

Passing engineering tests does not establish legal compliance. It demonstrates
that the deployed behavior matches the recorded owner policy and provides the
evidence needed for the responsible owner and counsel to decide release.

## 9. Authoritative references

- [OSM Standard tile usage policy](https://operations.osmfoundation.org/policies/tiles/)
- [OpenStreetMap copyright and ODbL](https://www.openstreetmap.org/copyright)
- [ArcGIS Static Basemap Tiles pricing and attribution](https://developers.arcgis.com/rest/static-basemap-tiles/)
- [Esri web/service terms](https://www.esri.com/en-us/legal/terms/web-site-service)
- [Esri World Imagery export limitations](https://www.esri.com/arcgis-blog/products/arcgis-living-atlas/imagery/wayback-export)
- [Sentinel-2 harmonized surface-reflectance catalog and terms link](https://developers.google.com/earth-engine/datasets/catalog/COPERNICUS_S2_SR_HARMONIZED)
- [OCI Middle East regions](https://www.oracle.com/middleeast/cloud/public-cloud-regions/)
- [OCI current flexible-compute prices](https://www.oracle.com/cloud/iaas-paas/)
- [OCI network pricing and first 10 TB egress](https://www.oracle.com/cloud/networking/virtual-cloud-network/pricing/)
- [DigitalOcean current regions](https://docs.digitalocean.com/platform/regional-availability/)
- [DigitalOcean current Droplet and backup prices](https://www.digitalocean.com/pricing/droplets)

All prices are planning estimates. Recreate them in the selected provider's
calculator immediately before purchase and retain the dated estimate.
