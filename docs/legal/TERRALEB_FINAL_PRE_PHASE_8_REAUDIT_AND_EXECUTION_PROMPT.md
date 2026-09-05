# TerraLeb final pre-Phase-8 re-audit, decisions and execution prompt

Status: **owner implementation direction; not legal advice or production authorization**

Prepared: **2026-08-25**

This report supersedes earlier cost and implementation assumptions where they
conflict with the repository state verified on the prepared date. It does not
approve a legal document, provider agreement, store declaration or production
release.

## 1. Outcome

The earlier Codex prompt must be narrowed. TerraLeb now already has the core
privacy-request, moderation, personal-data export, account-deletion,
notification and real-time administration workflows. Rebuilding them would risk
duplicate migrations, routes, workers and UI.

The remaining pre-Phase-8 work is:

1. migrate online Hybrid from anonymous legacy Esri URLs to supported ArcGIS
   Location Platform access;
2. replace the blocked Esri bulk-download path with a provider-neutral offline
   package built from an expressly redistributable source;
3. add the missing hardened production AI service overlay;
4. move growing files from single-host Docker volumes to private object storage;
5. reconcile the implemented deletion eligibility with the owner policy that an
   approved deletion discards drafts and pending/unapproved work;
6. complete production environment, secrets, ARM64, backup/restore and clean
   bootstrap evidence;
7. update the legal-readiness model so a deferred iOS release and an unused Esri
   offline source can be recorded as `not_in_release_scope` rather than falsely
   approved;
8. obtain the real operator, provider, store and counsel facts that code cannot
   create.

## 2. Verified repository state

The audit began from commit `abafdf6` on `handover-ready`, synchronized with
`origin/handover-ready`, with a clean worktree before the configuration changes
described in section 8.

The latest implementation includes:

- migrations through `0069`;
- a protected-super-admin Privacy & moderation workspace;
- privacy requests, content reports, corrections, encrypted asynchronous access
  exports, deletion execution records and a workload worker;
- one-time masked contributor labels and deleted-account tombstones;
- scoped WebSocket/Riverpod updates and worker-originated events;
- public legal routes and draft/version infrastructure;
- fail-closed legal, retention, deletion and release-readiness gates.

The current legal-readiness command deliberately reports **44 findings**. Most
are evidence/approval findings, not missing screens. The public legal catalog is
still draft content with decision placeholders, and production authorization is
correctly false.

Material gaps found in the current code are:

- `LebanonMapConfig` still hard-codes anonymous `World_Imagery` and
  `World_Boundaries_and_Places` URLs;
- no satellite URL/token/session/quota configuration exists in `AppEnv`;
- the current offline workflow attempts Esri satellite caching and correctly
  refuses it unless `LICENSED_ESRI_OFFLINE_BASEMAP_ENABLED=true`;
- no Copernicus/other open offline package builder is implemented;
- `compose.prod.yml` points to `http://ai-server:8000` but defines no production
  `ai-server` service; the only AI Compose file is expressly a historical
  research example and its external source repository is not present here;
- uploads and exports use local Docker volumes shared by the API and worker; no
  production object-storage adapter is present;
- deletion eligibility blocks draft and `pending_review` contributions and
  unresolved assignments rather than allowing a protected administrator to
  approve their discard/transfer under the latest owner policy;
- the deletion worker deletes only draft spatial features, not the full reviewed
  set of pending/unapproved records required by that policy;
- legal text still describes the older “finish pending work first” behavior;
- `.env.prod.example` was missing every recently added real-time, privacy,
  deletion, push, legal and provenance setting;
- privacy-export encryption and verification-HMAC values had no Docker secret
  mounts.

## 3. Online Street and Hybrid decision

### Street / OpenStreetMap

OSM data and the community Standard tile server are different things. Normal
interactive use of `tile.openstreetmap.org` does not require a purchase, but it
requires visible attribution, an identifying app User-Agent, proper caching and
no bulk/offline download. It has no SLA and access can be blocked if policy is
not followed.

TerraLeb may keep the current online Street workflow for normal human viewing
and drawing. The URL must remain configurable so TerraLeb can move to an
organization-owned or contracted OSM-derived service without a new UI.

Official policy:
[OpenStreetMap Standard Tile Usage Policy](https://operations.osmfoundation.org/policies/tiles/).

### Hybrid / ArcGIS satellite

The anonymous legacy World Imagery URL responding in development is not proof of
unlimited free production rights. TerraLeb should use an operator-owned ArcGIS
Location Platform account and the supported Basemap Styles or Static Basemap
Tiles service, with the basemap privilege, an approved credential pattern and
dynamic Esri/data attribution.

The initial usage model should be **tile usage**, because TerraLeb is a focused,
Lebanon-bounded application and the free allowance is large. Switch to sessions
only if a real pilot proves high tiles per app session.

Current official pricing is monthly:

| Model | Monthly free allowance | Overage |
|---|---:|---:|
| Basemap tiles | 2,000,000 returned tiles | $0.15 per 1,000 |
| Basemap sessions | 1,000 sessions, each up to 12 hours | $4 per 1,000 |

Billing occurs when a tile is returned. Browser/device cache hits are not
recorded as new tile usage. A map load, style change, zoom and pan can return new
tiles. TerraLeb also draws a separate reference-label layer, so Hybrid can use
roughly twice the tile requests of an imagery-only layer. The current map screen
uses `panBuffer=2` and `keepBuffer=3`, and Hybrid appears in multiple feature,
import, export and AI screens. Restricting the camera to Lebanon reduces the
possible area but does not make requests free or consume the whole country at
once.

A planning example, not a measurement:

- at 40-100 returned tiles per Hybrid use, two million tiles supports about
  20,000-50,000 such uses per billing month;
- 4.5 million tiles in one month would cost about $375 above the free tier;
- caching, screen size, zooming and reuse can change this substantially.

The app must instrument aggregate provider requests in a privacy-preserving way
and decide the model from a staging pilot. It must not infer cost from user count
alone.

If pay-as-you-go is disabled, ArcGIS removes service privileges after the free
tier is exhausted and restores them on the next billing cycle. TerraLeb must
keep drawing and collected project layers working by falling back to Street and
showing a short Hybrid-unavailable notice. If pay-as-you-go is enabled, usage
continues and the payment method is charged; provider credential restrictions,
daily monitoring, owner budgets and a remote kill switch are therefore required.

Recommended rollout:

1. closed pilot with pay-as-you-go disabled;
2. measure tiles per visible Hybrid session and monthly projection;
3. before public production, enable pay-as-you-go only if uninterrupted Hybrid
   is worth the approved monthly exposure;
4. keep provider fallback and the remote switch even when billing is enabled.

Official references:

- [ArcGIS Static Basemap Tiles](https://developers.arcgis.com/rest/static-basemap-tiles/)
- [ArcGIS basemap usage models](https://developers.arcgis.com/documentation/mapping-and-location-services/mapping/basemaps/basemap-usage-styles/)
- [ArcGIS Location Platform pricing](https://location.arcgis.com/pricing/)
- [ArcGIS billing and exhaustion behavior](https://location.arcgis.com/help/billing/)

## 4. Offline Hybrid decision

An offline map is not charged against the online ArcGIS tile allowance when it
is a TerraLeb-built package from a separate open dataset. Users download one
versioned file from TerraLeb storage. Costs are then only package production,
object storage and bandwidth.

For the no-imagery-purchase initial release, use a Lebanon package built from
Copernicus Sentinel-2 true-colour data plus OSM-derived labels. Sentinel data is
free, full and open for lawful reproduction, modification and distribution. A
modified product must carry wording equivalent to `Contains modified Copernicus
Sentinel data [year]`.

“Processing method” is not a purchase. It is the reproducible technical recipe:

- exact Sentinel product and scene IDs;
- acquisition date range and cloud threshold;
- cloud/shadow masking;
- true-colour bands and color scaling;
- mosaic rule for overlapping scenes;
- clipping to the approved Lebanon boundary;
- reprojection/resampling and tile/package format;
- zoom range, checksum, package version and generation tool versions.

“License evidence” is the retained terms URL/version, source notice and proof
that redistribution and offline device use are permitted. Open terms can satisfy
that evidence without a fee.

Sentinel-2 RGB is 10 m resolution. It is useful for regional orientation and
field context, but it is not a substitute for high-resolution imagery when a
contributor must trace a building or parcel. Keep the same Offline/Hybrid button
and drawing workflow, but show the source date and a brief accuracy notice. A
project needing finer offline tracing must supply institution-owned imagery or a
provider contract expressly permitting offline mobile redistribution.

Do not use Google Earth Engine merely to avoid writing the offline package
pipeline. TerraLeb can download Copernicus scenes from Copernicus Data Space and
process them on a controlled build worker with GDAL/raster tools. Earth Engine
may still be used for the app's approved AI pipeline under its actual commercial
or eligible institutional plan.

Official references:

- [Copernicus Sentinel-2 availability](https://dataspace.copernicus.eu/data-collections/copernicus-sentinel-missions/sentinel-2)
- [Copernicus Sentinel legal notice](https://sentinels.copernicus.eu/documents/247904/690755/Sentinel_Data_Legal_Notice)

## 5. Final hosting and storage decision

### Selected initial production target

Use **Oracle Cloud Infrastructure, Saudi Arabia West (Jeddah)**, subject to an
actual latency test from Lebanese mobile networks and ARM64 compatibility.

Start with:

- `VM.Standard.A1.Flex`, **6 OCPU / 32 GB RAM**;
- 300 GB balanced block storage for the OS, PostgreSQL/PostGIS and temporary
  processing space;
- OCI Object Storage Standard for uploads, photos, ordinary exports, encrypted
  privacy exports, AI outputs and offline packages;
- a separate Archive/backup bucket with lifecycle rules, plus a tested isolated
  restore;
- one host for the initial controlled release, with database and internal
  services private and only 80/443 public.

The repository's container limits reserve about 13.7 GB before the OS, Docker
overhead and AI. A 16 GB server is not safe. Six ARM cores provide better overlap
for ClamAV, imports, exports, workers and monitoring while remaining inexpensive.

Current planning cost, excluding tax and assuming 730 hours:

| Item | Calculation | Approx. USD/month |
|---|---:|---:|
| A1 compute | 6 × $0.01/OCPU-h + 32 × $0.0015/GB-h | $78.84 |
| 300 GB balanced block | capacity plus 10 VPU/GB planning rate | $12.75 |
| 250 GB Standard objects | first 10 GB free, then $0.0255/GB | $6.12 |
| 500 GB Archive backups | first 10 GB free, then $0.0026/GB | $1.27 |
| Requests, DNS, email, monitoring and second backup allowance | usage dependent | $5-25 |
| **Expected infrastructure total** | without ArcGIS/GEE/tax | **about $105-125/month** |

Budget **$105-135/month** to allow growth and cross-region backup operations.
Do not depend on Always Free capacity in the production budget even though a
paid tenancy may receive allowances. OCI publishes the first 10 TB/month of
outbound transfer free in Middle East/Africa regions.

If any required image or scientific dependency fails ARM64 tests, use OCI
`VM.Standard.E4.Flex`, 4 OCPU/32 GB x86. Compute is about $108/month before
storage, and the full starting budget is roughly $135-165/month.

DigitalOcean is not selected: its verified region list has no Middle East data
center, and a dedicated 32 GB memory-optimized Droplet is $168/month before
backups. Its $5/250 GiB Spaces storage is good, but does not overcome the region
and compute-price difference.

Official references:

- [OCI live Middle East regions](https://www.oracle.com/middleeast/cloud/public-cloud-regions/)
- [OCI A1 pricing](https://www.oracle.com/cloud/compute/arm/)
- [OCI storage price list](https://www.oracle.com/cloud/price-list/)
- [OCI network pricing](https://www.oracle.com/cloud/networking/virtual-cloud-network/pricing/)
- [DigitalOcean regions](https://docs.digitalocean.com/platform/regional-availability/)
- [DigitalOcean Droplet prices](https://www.digitalocean.com/pricing/droplets)

### Storage implementation rule

Do not simply mount object storage as an unreliable shared filesystem. Add a
small storage abstraction with local and S3-compatible OCI implementations.
Use private buckets, server-side encryption, least-privilege identities,
checksums, content-type validation and authenticated streaming or short-lived
grants. Privacy exports remain application-encrypted and require reauthentication
before the API decrypts/streams them. Database files remain on block storage;
database backups go to object/archive storage.

## 6. Settled owner decisions

The implementation may proceed using these owner directions, but the exact
public wording and legal conclusions still require approval:

- distribution: Lebanon only;
- launch platforms: Android and web; iOS source retained but not in the initial
  public release;
- minimum age: 18+, no minor accounts in v1;
- analytics/advertising SDKs: none unless separately approved;
- AI: deployed at environment level, disabled on every new project by default,
  protected-super-admin enable/run/review/publish controls, project GIS only,
  no account/contact/session data, no general or cross-project training;
- maps: online OSM Street, supported ArcGIS online Hybrid, Copernicus/OSM-derived
  offline Hybrid; no public-server bulk scraping;
- deletion: every non-protected-super-admin role may request; protected admin
  review; accepted GIS and minimum approved provenance retained under a masked
  label; direct identifiers/credentials and drafts/pending/unapproved material
  removed after responsibility transfer and approval;
- production database: fresh and empty except the protected super administrator;
- hosting: OCI Jeddah A1 6/32, with x86 E4 fallback after compatibility tests.

## 7. Remaining blockers

### Engineering blockers Codex can close

1. Supported online ArcGIS provider adapter, authentication, attribution,
   provider state, usage measurement and fallback.
2. Provider-neutral offline package interface and reproducible Copernicus build.
3. Hardened production AI overlay. The actual AI repository/image must be
   supplied or checked out at an approved path; it is not in this repository.
4. OCI object-storage adapter and migration of new file writes, with a controlled
   migration plan for old files.
5. Latest deletion policy implementation and matching legal/UI wording.
6. Release-readiness schema v2 with evidence-backed `approved`, `blocked` and
   `not_in_release_scope`; no false approvals.
7. ARM64 build/load evidence, backup/restore, clean bootstrap and performance.
8. Final mobile production defines, identifiers, map configuration and Firebase
   build configuration.

### External facts/actions engineering cannot close

1. Exact legal operator/controller name, status and physical address.
2. Public privacy contact and operational inbox.
3. Controlled production domain and Android package ID.
4. OCI, ArcGIS, Copernicus, Firebase/Google Play and email provider accounts,
   agreements and credentials.
5. Approved retention periods and institutional basis for retained GIS records.
6. Exact treatment/visibility of accepted photos, precise locations, free text
   and masked attribution.
7. Backup ageing and legal-hold rule.
8. Governing law/dispute wording and Law 81 formalities based on the Arabic
   Official Gazette text.
9. Exact Arabic/English policy versions and counsel approval reference.
10. Google Play declarations and signed-build evidence.

These items must not be replaced with invented values or a boolean set to true.

## 8. Configuration corrections already applied during this re-audit

The following safe engineering corrections were made:

- `.env.prod.example` now lists all current API schema settings, including
  scoped real-time, privacy request/report limits, offline sync, image/import
  limits, encrypted exports, deletion gates, push, legal drafts and provenance;
- production defaults explicitly disable legal drafts, the legacy real-time
  broadcaster and polling fallback;
- Android push is requested, iOS push is off for the initial scope;
- a proposed 72-hour encrypted privacy-export TTL is present, but production
  still fails closed without its approval reference;
- the API entrypoint can load privacy-export and verification-HMAC secrets from
  files;
- Compose mounts those secrets to the correct API/worker services and mounts the
  Firebase service-account file only to the API;
- the production configuration verifier checks this wiring.

No real secret, domain, operator identity, counsel reference or provider
credential was created.

## 9. Updated prompt to give Codex

```text
You are working in the TerraLeb GIS repository at D:\GIS_APP.

Implement the remaining pre-Phase-8 production work. Begin by re-reading all
repository guidance, the current worktree, migrations, latest implementation
report, this file, current tests and deployment configuration. Preserve every
user change. Never reset the repository, edit a deployed migration, fabricate a
provider/legal fact, or mark a release gate approved without immutable evidence.

CURRENT VERIFIED BASELINE (2026-08-25)

- Privacy requests, moderation, corrections, asynchronous encrypted personal-data
  exports, deletion execution, protected-super-admin UI and scoped real-time
  updates are already implemented. Do not rebuild or duplicate them.
- Current migrations end at 0069.
- The legal-readiness gate intentionally has 44 unresolved approval/evidence
  findings.
- Online Street is OSM Standard.
- Online Hybrid still uses hard-coded anonymous legacy Esri World Imagery and
  reference-label URLs.
- Esri offline bulk download is correctly disabled by default; no open offline
  package pipeline exists.
- compose.prod.yml has no production ai-server service even though the API points
  to one. The historical AI research Compose file is not production-authorized.
- Uploads/exports are local Docker volumes; no OCI object-storage adapter exists.
- Deletion currently blocks pending work and only removes draft features, which
  does not yet match the owner policy below.
- Production env/secret templates were recently completed for current API
  settings; verify and extend them rather than undoing them.

OWNER PRODUCT POLICY

1. Lebanon-only Android/web initial release; iOS is not in this release scope but
   source must remain buildable.
2. Users are 18+ in v1.
3. AI must be deployed. Every project defaults disabled. Only the protected
   super administrator may enable/run/review/publish. AI inputs are allowlisted
   project GIS/geometries/approved datasets; exclude account, contact, session,
   device, notification and private-draft data. Do not train a general or
   cross-project model.
4. Preserve Street, Hybrid, drawing and offline workflows.
5. Online Street uses OSM interactively with attribution, identifying client,
   cache compliance and no bulk/offline use.
6. Online Hybrid uses an operator-owned supported ArcGIS Location Platform
   Basemap Styles/Static Tiles integration. Start with tile usage; implement
   session support only if measured usage justifies it.
7. Offline Hybrid uses a TerraLeb-hosted Lebanon package made from Copernicus
   Sentinel-2 and OSM-derived labels. It must show source date and 10 m accuracy
   notice. Never scrape OSM or Esri public tile servers.
8. On approved deletion, erase credentials/direct identifiers and discard
   drafts, pending/unapproved content and unnecessary attachments. Transfer or
   release active responsibilities. Retain accepted GIS and only its approved
   minimum institutional provenance under the existing one-time masked label.
   Do not call it anonymization.
9. Production starts with an empty migrated database and only the protected
   super administrator.
10. Target OCI Jeddah A1 6 OCPU/32 GB, 300 GB balanced block and private object
    storage. Use OCI E4 x86 4 OCPU/32 GB only if ARM64 evidence fails.

PRESERVATION RULES

- Do not remove or redesign existing features, roles, visibility, forms,
  offline sync, reviews, imports, exports, AI, notifications or legal workflows.
- REST remains authoritative. Do not add polling.
- Keep server-side authorization, fail-closed completion and reauthentication.
- Do not expose provider keys, PII, geometry or legal text in logs/events.
- Any necessary user-visible change requires old/new behavior, reason,
  compatibility, tests and deployment/training impact in the final report.
- Work phase by phase and run relevant tests after each phase.

PHASE 0 - RE-AUDIT AND BASELINE

- Inspect git status/history, all current changes, migrations, map screens/tile
  layers, offline manager, AI routes/workers/external dependency, storage paths,
  deletion worker, legal catalog/readiness scripts, mobile build config and
  production Compose.
- Record backend/Flutter/Docker tests, map tile requests per representative
  screen, API/database p50/p95, memory, ARM64 image availability and current
  object/file volumes.
- Produce a dependency map before editing.

PHASE 1 - PRODUCTION CONFIGURATION AND READINESS MODEL

- Verify the new Docker secret wiring for privacy exports, verification HMAC and
  Firebase; add regression tests.
- Add complete, documented production configuration for map provider, object
  storage, AI service, budgets and mobile release defines without committing
  secrets.
- Upgrade legal readiness to a versioned status/evidence model supporting
  approved, blocked and not_in_release_scope. iOS store checks and Esri offline
  licensing may be not_in_release_scope only with recorded Android/web and
  Copernicus-offline evidence. Add Copernicus source readiness; do not mark Esri
  offline approved.
- Keep production authorization false.

PHASE 2 - OCI STORAGE AND DEPLOYMENT

- Add a small storage interface with local development and S3-compatible OCI
  implementations.
- Move new uploads/photos/import artifacts/ordinary exports/encrypted privacy
  exports/AI outputs/offline packages to private object storage. Keep Postgres on
  block storage.
- Use checksums, server-side encryption, least privilege, authenticated access,
  short-lived grants where safe, streaming, expiry and cleanup. Privacy exports
  remain application-encrypted and reauthenticated through the API.
- Add controlled legacy-file migration/reconciliation, idempotency and rollback.
- Add OCI Jeddah IaC/runbook, budgets, network rules and ARM/x86 choice gate.

PHASE 3 - ONLINE MAP PROVIDERS

- Centralize Street/Hybrid provider configuration and remove anonymous hard-coded
  production Esri URLs.
- Implement supported ArcGIS Location Platform tile authentication without
  shipping an unrestricted long-lived secret. Handle token expiry, 401/403/429,
  quota exhaustion, provider outage and remote disable.
- Preserve map camera, drawing, overlays and forms; fallback affects only the
  basemap and must not discard work.
- Fetch/display exact dynamic Esri/data attribution; keep compact attribution
  above drawers and accessible.
- Honor OSM caching and identifying-client rules.
- Add low-cardinality tile/session/failed-request metrics and pilot measurement;
  no geometry/coordinates in logs.

PHASE 4 - OFFLINE HYBRID PACKAGE

- Add a reproducible controlled build for a low-cloud Sentinel-2 true-colour
  Lebanon mosaic and OSM-derived labels.
- Record scenes, dates, cloud mask/composite, bands, reprojection, zooms,
  resolution, tools, terms, attribution, checksum and package version.
- Integrate through the existing authenticated resumable offline package flow,
  account isolation, safe replacement and storage-pressure behavior.
- Remove/retire the Esri bulk-caching execution path after staging proves the
  replacement, while preserving a provider-neutral path for later licensed
  high-resolution packages.
- Show a brief source/date/10 m orientation notice. Do not claim cadastral or
  survey accuracy.

PHASE 5 - PRODUCTION AI

- Locate the actual AI repository/image. If it is unavailable, stop this phase
  and report the exact required artifact; do not promote the research Compose
  example.
- Build a hardened internal-only production overlay with pinned image/digest,
  health, timeouts, concurrency, restart/resume, secret mounts, output storage,
  callback authentication and observability.
- Keep environment AI enabled and each project default false.
- Enforce protected-super-admin controls and a serialized request allowlist.
- Test no PII/private drafts, project isolation, GEE/account plan, outage,
  duplicate callback, cost cap, review/publication/retraction and ARM64.

PHASE 6 - DELETION POLICY RECONCILIATION AND DOCUMENTS

- Add an explicit protected-admin discard/transfer decision with transactional
  counts of accepted versus draft/pending/unapproved records.
- Recheck eligibility under row locks immediately before execution.
- Delete all policy-approved unfinished records and attachments; release/transfer
  assignments, reviews, imports, exports, AI and moderation responsibilities.
- Preserve accepted GIS geometry and minimum approved provenance, tombstone and
  masked label. Keep retries idempotent and rollback safe.
- Update user/admin wording and legal drafts to match actual behavior only after
  tests pass.
- Keep ACCOUNT_DELETION_EXECUTION_ENABLED=false until approved references and
  full tests exist.

PHASE 7 - CLEAN BOOTSTRAP, VERIFICATION AND HANDOFF

- Add/prove production bootstrap with migrations and only protected super admin;
  forbid dev/test seeds and fake acceptances.
- Build/test all production images on ARM64; select x86 fallback if any gate
  fails.
- Run full backend formatting/lint/typecheck/build/unit/integration/security/
  performance/migration/release tests; Flutter format/analyze/unit/widget/
  integration/Android/web builds; Docker/Nginx/WebSocket/worker tests.
- Prove backup, isolated restore, deletion, privacy export, push, AI, online and
  offline maps, provider exhaustion/fallback, disk full, restart and rollback.
- Measure p50/p95, database queries, object operations, map usage, memory and
  cost. No unjustified >5% regression.
- Produce an exact click-by-click Phase-8 manual checklist and evidence package.

MANDATORY ACCEPTANCE

- Existing workflows remain available and no unsaved form/draft is lost.
- Online Hybrid uses supported authenticated ArcGIS access, not anonymous legacy
  production URLs.
- ArcGIS exhaustion/outage cannot break GIS overlays or drawing.
- OSM/Esri public bulk download is impossible.
- Offline Hybrid works in airplane mode from a verified open package.
- AI is production-deployable, project-default off and protected-super-admin
  controlled, with no account/PII inputs.
- New file artifacts use private object storage and restore is proven.
- Deletion retains accepted GIS, removes approved unfinished work/direct
  identifiers and is idempotent.
- Production env contains no placeholders or inline secrets.
- Legal readiness truthfully distinguishes blocked and out-of-scope items.
- Passing tests does not set productionAuthorized or establish legal compliance.

FINAL REPORT

Provide architecture, files, migrations, behavior changes, map usage/cost
measurements, offline source/provenance, AI deployment, exact deletion retention,
storage/backup design, configuration matrix, tests/results, remaining external
facts, OCI cost estimate, deployment/rollback and an “Existing feature or
behavior changes” section with previous/new/reason/compatibility/tests/impact.
```

## 10. Owner click-by-click manual setup

Do not paste any secret into a task, screenshot, Git issue or policy document.
Store evidence references, not credentials.

### A. Identity, scope and domain

1. Write the exact legal operator name and legal/public-body status.
2. Write its physical address and Lebanon jurisdiction/registration reference.
3. Create a role inbox such as the final privacy address on the controlled
   domain; assign at least two responsible people and enable MFA.
4. Confirm in writing: Lebanon only, 18+, Android/web v1, iOS deferred, no ad or
   analytics SDK, project-only AI and no cross-project training.
5. Register/control the final domain and create DNS for the app/API and public
   legal pages.
6. Choose the final Android application ID once; changing it later creates a
   different Play application.

### B. OCI tenancy and server

1. Create an organization-owned OCI paid tenancy; choose home region carefully.
2. Enable MFA for the owner and create separate least-privilege administrators.
3. Create compartment `terraleb-production`.
4. Create a monthly budget of **$135** with notifications at 50%, 70%, 90% and
   100%; add a second notification channel.
5. In Jeddah, create a VCN with a public subnet for Nginx and private access for
   internal services. On a single VM, Docker networks still keep internal ports
   private.
6. Security list/network security group: allow inbound 80/443; allow SSH only
   from approved administrator IPs or a VPN. Do not expose 3000, 5432, 6379,
   8000, 9090, 3100 or 3310.
7. Create `VM.Standard.A1.Flex` with 6 OCPU and 32 GB, Ubuntu LTS ARM64 and the
   individual SSH keys.
8. Attach 300 GB balanced block storage. Enable encryption and monitoring.
9. If A1 capacity is unavailable or Phase 7 ARM tests fail, create E4 Flex x86
   4 OCPU/32 GB instead; do not force incompatible images into production.
10. Reserve the public IP, attach DNS and validate latency from at least two
    Lebanese mobile networks before release.

### C. OCI object and backup storage

1. Create private Standard buckets/prefixes for `uploads`, `exports`,
   `privacy-exports`, `ai-outputs` and `offline-packages`.
2. Create a private backup/archive bucket and lifecycle rules matching the
   approved backup policy.
3. Enable versioning only where the retention/deletion rule permits it; otherwise
   versioning can keep data longer than promised.
4. Create dynamic-group/instance-principal policies or a least-privilege S3
   compatibility key scoped to only the required buckets.
5. Record region, encryption, lifecycle, DPA/terms and IAM policy references in
   the subprocessor/data-flow registers.
6. After deployment, restore one encrypted database backup and a representative
   object set into an isolated replacement environment and record the result.

### D. ArcGIS online Hybrid

1. Create an organization-owned ArcGIS Location Platform account.
2. Dashboard -> developer credentials -> create TerraLeb production
   credentials with only the basemap privilege.
3. Restrict the credential to the final app/domain/package patterns supported by
   the chosen authentication method.
4. Leave pay-as-you-go off during the closed pilot.
5. Run the instrumented pilot and record returned tiles per screen/session,
   cache behavior and projected monthly cost.
6. If projected use is below the approved exposure, add the payment method and
   enable pay-as-you-go for continuity. If zero overage is mandatory, keep it off
   and formally accept the Street fallback after free-tier exhaustion.
7. Review the Usage page daily during the pilot and weekly after release.
8. Verify imagery and underlying-provider attribution at Lebanon zoom levels on
   every TerraLeb map screen.

### E. Offline Hybrid data

1. Create a Copernicus Data Space account under the operator if API/download
   access requires it.
2. Select the acquisition season/date range and maximum cloud percentage with
   the GIS owner.
3. Run the repository package builder on a controlled worker.
4. Review coverage/clouds visually; record all scene IDs and processing options.
5. Sign the manifest containing `Contains modified Copernicus Sentinel data
   [year]`, OSM attribution, 10 m resolution, checksum and version.
6. Upload to the private offline-package bucket and register it through the
   protected TerraLeb workflow.
7. On two Android devices, test download interruption/resume, checksum,
   airplane-mode rendering, account switching, storage pressure and deletion.
8. If 10 m is insufficient for a project, obtain written rights to an authorized
   higher-resolution package; do not silently return to Esri scraping.

### F. Firebase, email and notifications

1. Firebase Console -> create/select the organization project.
2. Add the final Android package ID and complete the release SHA/signing setup.
3. Download the backend service-account JSON once and place it only in the
   production secret store/file named by the deployment template.
4. Add the Flutter Firebase configuration through the supported platform files;
   do not put service-account credentials in the app.
5. Configure the real SMTP provider, verify the sending domain and sender, and
   store its password in the Docker secret file.
6. Test signup verification, password reset and generic lock-screen push text on
   a physical device. Notification details must still be fetched after login.

### G. Secret and environment preparation

1. Copy `.env.prod.example` to the production-only `.env`; never commit it.
2. Replace all `example`/placeholder hostnames, operator email and SMTP values.
3. Create unique random DB, JWT, refresh, Valkey, metrics, super-admin, SMTP and
   AI callback secret files listed in the template.
4. Generate a random 32-byte value, base64 encode it and store only the encoded
   value in `privacy_export_encryption_key.txt`.
5. Generate a separate random value of at least 32 bytes for
   `verification_hmac_secret.txt`.
6. Place the Firebase JSON at `firebase_service_account.json` with restrictive
   permissions.
7. Do not enable legal enforcement, import-provenance enforcement or deletion
   execution until their exact approved evidence references are available.
8. After the AI production overlay passes, set environment AI enabled and the
   validated production mode while retaining project `is_enabled=false` by
   default.
9. Run Compose rendering, environment validation and release gates before any
   container starts publicly.

### H. Retention, legal text and Play

1. Approve or amend the proposed 72-hour privacy-export TTL and record an
   immutable owner/counsel reference.
2. Decide the exact periods for logs, sessions, notifications, temporary
   imports, ordinary exports, AI artifacts, privacy cases, audit evidence,
   accepted GIS and backups. Do not use “indefinite” without a specific approved
   institutional/public-record basis.
3. Approve 35 days as the proposed maximum normal backup ageing period or record
   the replacement; define legal holds separately.
4. Decide whether masked attribution is public, project-member-only or
   protected-admin-only, and how accepted photos/location/free text are handled.
5. Have qualified Lebanese counsel verify Law 81 article references against the
   Arabic Official Gazette and decide any notification/permit requirement.
6. Insert the real facts into Arabic and English Privacy, Terms, AUP, Important
   Notices, deletion and subprocessor documents.
7. Counsel approves exact document hashes; store approval references without
   privileged correspondence.
8. Publish stable HTTPS legal/deletion pages and test them logged out.
9. Play Console -> App content: complete Privacy Policy, Data Safety, account
   deletion, target audience 18+, permissions and content reporting from the
   exact signed AAB and production behavior.
10. Restrict country distribution to Lebanon and use closed testing first.
11. Attach test, map, AI, deletion, backup/restore, performance and cost evidence
    to the release record.
12. Only the named release owner may set production authorization for the exact
    build after counsel and engineering evidence are complete.

## 11. Release statement

There are still blockers, but they are now specific and actionable. Engineering
can complete Phases 0-7. Phase 8 requires real accounts, identities, provider
agreements, store actions, measured evidence and legal approval. Passing tests
does not itself establish legal compliance.
