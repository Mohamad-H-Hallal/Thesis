# TerraLeb revised owner policy, hosting cost and deployment plan

> Hosting/provider sections were superseded on 2026-09-05 by
> `TERRALEB_DIGITALOCEAN_HOSTING_DECISION_V2.md`. This file is historical.

> **Superseded for execution on 2026-08-25:** use
> [`TERRALEB_FINAL_PRE_PHASE_8_REAUDIT_AND_EXECUTION_PROMPT.md`](TERRALEB_FINAL_PRE_PHASE_8_REAUDIT_AND_EXECUTION_PROMPT.md).
> This file remains as historical decision context.

> **2026-08-19 regional-hosting and zero-purchase-map decision:** the later
> [`TERRALEB_MAP_AND_REGIONAL_HOSTING_DECISION.md`](TERRALEB_MAP_AND_REGIONAL_HOSTING_DECISION.md)
> clarifies the app's actual Street/Hybrid sources, selects a no-purchase map
> path, and adds Oracle Cloud Jeddah as the recommended regional low-cost host.
> Where the two reports differ, the later decision controls.

Status: **owner decision and implementation plan - not production authorization**

Prepared: **2026-08-18**

Currency: **USD unless stated otherwise; taxes, exchange fees and paid labour excluded**

## 1. Final product direction recorded by this report

This report replaces the earlier proposal to disable AI and Esri/map modes.

1. **AI stays in the product and is deployed.** Every project starts with AI
   disabled. Only the protected super-admin can enable it for a project, run or
   resume it, validate/reject results and decide whether a reviewed result is
   published.
2. **AI input is project GIS data, not account data.** The production integration
   must allow only approved AOI/geometries, label fields, training samples and
   approved imagery/datasets. Names, email, phone, credentials, sessions, device
   tokens, contributor IDs, notifications and private drafts are excluded.
3. **No general or cross-project AI training.** A project run may learn/classify
   from samples approved for that project only. It must not improve an external
   general model or reuse data for another project.
4. **All Street and Satellite map experiences remain.** Compliance is achieved
   by correcting provider access and offline sources, not removing map buttons.
5. **Online OSM remains for modest interactive use** with attribution, an
   identifying User-Agent, HTTP caching, no prefetch/bulk use and monitoring.
6. **Online satellite remains through licensed ArcGIS access.** Replace the
   anonymous legacy World Imagery URL with an ArcGIS Location Platform/Online
   token or session flow and complete provider attribution.
7. **Offline Street remains** using a TerraLeb-controlled Lebanon package
   generated from an OSM database extract - not by scraping the public OSM tile
   server.
8. **Offline Satellite remains as a capability**, but the installed package must
   come from imagery with explicit device/offline redistribution rights. The raw
   Esri public endpoint must not be bulk-downloaded.
9. **Deletion keeps accepted GIS and its minimum final provenance.** When a
   protected administrator approves deletion, drafts, unsynchronized work,
   pending/unapproved contributions and unapproved attachments are deleted with
   the account. Accepted GIS, the final approval/review fact and required source
   provenance remain under the masked contributor policy.
10. **Production starts empty.** Seed/test accounts, projects, GIS, AI runs,
    imports, exports and fake legal acceptances are excluded. This simplifies
    migration but does not remove the need for provider rights, correct notices,
    secure deletion, backups or store evidence.

The updated source policy is
[`TERRALEB_OWNER_DECISIONS_AND_BLOCKER_CLOSURE_FORM.md`](TERRALEB_OWNER_DECISIONS_AND_BLOCKER_CLOSURE_FORM.md).

## 2. Important legal and technical clarification

### GIS data and AI

GIS geometry is not automatically harmless merely because it has no user name.
It may reveal a home, private parcel, sensitive habitat, infrastructure or other
restricted site. TerraLeb may still process it with AI under the owner policy,
but must enforce project authorization and sensitive-site classification.

A checkbox cannot make TerraLeb the owner of data the contributor never owned.
The safer product rule is:

- contributors retain whatever rights they actually possess;
- contributors grant TerraLeb and the responsible project institution a clear,
  royalty-free licence to host, validate, transform, analyze with the approved
  project AI, review, publish when separately authorized, and export accepted GIS;
- that licence survives account deletion for accepted official records during
  the approved retention period;
- third-party/institutional imports still require source and licence authority.

This gives TerraLeb the operational rights it needs without making an ownership
claim that may be false.

### Map URLs

Opening a public URL is not the same as receiving every reuse right:

- OSM data is open under ODbL, but the community-operated Standard tile servers
  have a separate usage policy. Interactive display can be acceptable; bulk and
  offline prefetch are prohibited.
- Esri's online services are available under their account, service and data
  terms. Current supported basemap APIs use credentials and require Esri/data
  attribution. Offline availability depends on the specific product and data;
  anonymous access to a tile URL is not permission to copy an entire area.

Therefore no TerraLeb map type needs to disappear, but online and offline may use
different compliant sources.

## 3. Repository sizing basis

The production Compose limits currently reserve approximately:

| Always-on component | Memory limit |
|---|---:|
| PostgreSQL/PostGIS | 2 GB |
| ClamAV | 4 GB |
| Valkey | 0.5 GB |
| Node API | 1.5 GB |
| Workload worker | 2 GB |
| Nginx/certificate services | about 0.75 GB |
| Prometheus, Alertmanager, Blackbox, Loki and Alloy | about 2.9 GB |
| **Configured total before OS, Docker, migration and AI** | **about 13.7 GB** |

A 16 GB host is therefore too tight for the complete production stack plus the
AI service. The practical single-host starting size is **32 GB RAM**. CPU limits
are ceilings and are not all consumed continuously, but imports, ClamAV, exports,
AI callbacks and map-package work can overlap. Production sizing must be verified
with the repository load tests and one realistic AI run.

The AI pipeline uses Google Earth Engine for major geospatial work, so the local
Python service is primarily orchestration, validation and output handling unless
the external pipeline performs additional local computation. No GPU is currently
justified by the inspected deployment design.

## 4. AWS Bahrain price plan

AWS prices vary by region, architecture, usage and commitment. The figures below
are planning estimates for 730 hours/month and must be recreated in the AWS
Pricing Calculator on the purchase date. Bahrain does not currently appear in
the official Lightsail region list, so the cheap Lightsail bundles are not a
Bahrain option.

### Option A - one AWS EC2 host, suitable for pilot/initial production

| Item | Planning configuration | Estimated monthly |
|---|---|---:|
| EC2 ARM compute | `t4g.2xlarge`, 8 vCPU, 32 GB | about $234 |
| Alternative x86 compute | `t3.2xlarge`, 8 vCPU, 32 GB | about $293 |
| EBS gp3 | 320 GB | about $32 |
| Public IPv4 | one address at $0.005/hour | $3.65 |
| S3/private objects | first 100 GB plus ordinary requests | about $3–8 |
| EBS/database backup snapshots | small changing 200–320 GB workload | about $12–30 |
| Route 53 | one hosted zone plus light DNS queries | about $0.50–1 |
| SES | 10,000 ordinary outgoing messages | about $1 plus attachment data |
| CloudWatch/alarms/logs | tightly retained low-volume telemetry | about $5–25 |
| Secrets/KMS/container registry | small deployment | about $5–15 |
| Internet transfer | first 100 GB aggregated free; next usage depends on region | about $0–30 at small scale |
| AWS support | Basic $0; optional Business Support+ minimum | $0 or $29+ |
| **ARM total** | without GEE/map commercial licences/tax | **about $296–409** |
| **x86 total** | without GEE/map commercial licences/tax | **about $355–468** |

ARM is cheaper, but every Node, PostGIS, ClamAV, monitoring and Python/AI image
must be proven multi-architecture. Use x86 if any scientific dependency fails on
ARM; do not discover this during go-live.

This design keeps the database, cache, API, worker, AI, scanner and monitoring on
one host. It is recoverable from off-host backups but is not highly available.

### Option B - AWS managed/high-availability production

| Item | Typical shape | Estimated monthly |
|---|---|---:|
| Two application/worker nodes | 2 × 8 GB burstable instances | $115–180 |
| Dedicated AI orchestrator | 8–16 GB instance | $60–150 |
| RDS PostgreSQL/PostGIS Multi-AZ | 4–8 GB plus 100–200 GB storage/backups | $180–300 |
| ElastiCache/managed Valkey | small primary/replica | $30–80 |
| Application Load Balancer | base hours plus light LCUs | $20–40 |
| Private-network egress | NAT gateway(s) and processing, or a carefully designed lower-cost alternative | $35–100 |
| S3, backups, monitoring, DNS, IPs, secrets and transfer | usage dependent | $40–120 |
| Business Support+ | optional but useful for production | $29+ |
| **Estimated AWS HA total** | before GEE/map licences/tax | **about $510–999/month** |

The upper/lower range depends mainly on RDS Multi-AZ size, NAT architecture, log
volume, transfer and whether AI needs a dedicated larger node. A two-AZ design
should not pretend to be HA while retaining a single local disk or single-host
database.

### AWS one-time/annual costs

- Google Play developer registration: **$25 one time**.
- Domain registration: provider/TLD dependent; budget **$10–50/year** until the
  actual `.lb` registrar quote and eligibility are known.
- TLS certificate: **$0** with the existing Let's Encrypt flow or AWS ACM where
  applicable.
- AWS setup fee: normally **$0**, excluding professional services.
- Engineering/operations labour, institution procurement and Lebanese counsel:
  **not included** and must be quoted by the actual providers.

## 5. AI and map usage costs

These costs apply regardless of whether the API is hosted on AWS or Hetzner.

### Google Earth Engine

| Option | Published price | TerraLeb use |
|---|---:|---|
| Eligible non-commercial/research access | potentially no platform charge, subject to Google's approval and conditions | Use only if the real operator/project qualifies; do not self-declare eligibility. |
| Limited plan | no monthly platform fee; usage charged | Best first commercial choice for infrequent super-admin runs. Current published compute rate starts around **$0.40/EECU-hour**, plus storage/egress. |
| Basic enterprise | **$500/month** including stated compute/storage credits | Consider only when runs are regular and predictable. |
| Professional | **$2,000/month** | Not justified for a fresh launch. |

Start with an approved Limited or eligible non-commercial account, configure a
budget alert, and measure EECU cost per project before considering Basic.

### Online maps

| Source | Published cost/limit | Recommended use |
|---|---:|---|
| OSM Standard public tiles | no monetary charge; no SLA; strict usage policy | Modest interactive Street map only; identifying User-Agent, caching, attribution, no offline/bulk use. |
| ArcGIS Location Platform basemap tiles | first **2 million tiles free**, then **$0.15/1,000 tiles** | Good low-cost online Satellite replacement for the raw endpoint. |
| ArcGIS basemap sessions | first **1,000 sessions free**, then **$4/1,000 sessions** | Consider for highly interactive/long sessions after measuring tile volume. |
| MapTiler Cloud Flex alternative | **$25/month**, published quotas and overage pricing | Optional single-vendor online Street/Satellite fallback if ArcGIS/OSM operations are undesirable. |

### Offline maps

| Source | Cost | Decision |
|---|---:|---|
| TerraLeb-generated Lebanon OSM package | infrastructure/storage plus implementation; no public-tile charge | Recommended for offline Street. Meet ODbL attribution and derived-database obligations. |
| Institution-owned/licensed Lebanon imagery | contract dependent | Best offline Satellite choice if NCRS/CNRS/another institution already has redistribution rights. Obtain the licence in writing. |
| MapTiler on-prem Standard | published **$2,500/year**, limited to one internal production app and up to 500 MAU; medium-resolution satellite | Possible only if TerraLeb's distribution fits those terms. Public/government/B2C or high-resolution use needs a custom quote. |
| Esri/ArcGIS offline package | account/product/data specific | Obtain a written quote and confirm that the Flutter/current-package delivery model is permitted. Do not assume the online free tier covers it. |

Offline Satellite is the only unavoidable provider/licence decision still open.
The feature stays; production download remains fail-closed until a compatible
dataset is selected.

## 6. Lower-cost hosting alternatives

### Recommended initial deployment - Hetzner Cloud EU

For a fresh, controlled Lebanon release, the best price/performance option is a
single x86 **CX53** in Nuremberg or Falkenstein, plus off-host object storage and
backups. Hetzner's published June 2026 price adjustment lists CX53 at about
**$34.99/month excluding VAT**, with 16 shared vCPU, 32 GB RAM and 320 GB disk.

| Item | Estimated monthly |
|---|---:|
| Hetzner CX53, 32 GB/320 GB | $34.99 |
| Primary IPv4 | about $0.60 |
| Automatic server backups | about 20% of server price: $7 |
| Hetzner Object Storage, 1 TB storage/1 TB egress bundle | about $5.99 |
| Extra encrypted database/object backup allowance | $3–10 |
| Transactional email | $0–15 at launch volume |
| External uptime check/status delivery | $0–10 |
| Domain amortized | about $1–5 |
| **Infrastructure total** | **about $53–84/month** |

Add GEE and any offline-satellite licence separately. With Limited GEE and usage
of 25 EECU-hours, for example, add approximately $10 compute plus storage/egress.

Advantages:

- approximately one fifth to one third of the comparable single-host AWS Bahrain
  cost;
- x86 compatibility for the existing Docker and scientific stack;
- large included EU traffic and simple predictable billing;
- S3-compatible object storage and documented DPA/security controls.

Trade-offs:

- data is processed in the selected European country, not Bahrain;
- higher network distance must be measured from Lebanon on real mobile networks;
- shared CPU can vary under noisy-neighbour load;
- PostgreSQL, Valkey, Docker, OS patching, failover and recovery are TerraLeb's
  responsibility;
- a single server is a single availability point even with good backups.

This is the recommended **pilot and initial-production** choice, not the final
high-availability architecture. Move to dedicated vCPU/separate database or AWS
when p95 latency, CPU steal, queue depth, concurrent WebSockets, recovery target
or an institution's region/procurement requirement crosses an approved threshold.

### Other alternatives

| Provider | Comparable starting shape | Approximate monthly | Assessment |
|---|---|---:|---|
| DigitalOcean | 16 GB/8 shared vCPU Droplet | $96 + about 20% backups + $5 object storage | Easier interface and predictable transfer, but 16 GB is tight; two nodes or a larger design removes most savings. |
| AWS Lightsail | 32 GB bundle listed at $164 | about $170–210 with storage/backups | Predictable and simpler AWS, but not available in Bahrain on the current official region list. |
| Oracle/other free tiers | variable | potentially very low | Not recommended for production because capacity, support and continuity are less predictable. |

There is no provider that is simultaneously cheaper than Hetzner and objectively
better than AWS at every service level. The correct choice is:

- **Hetzner** for lowest practical initial cost and simple Compose deployment;
- **AWS Bahrain** for nearby regional services, managed components, procurement
  maturity and a clearer HA growth path.

## 7. Recommended budget decision

Adopt this staged budget unless an institution requires Bahrain immediately:

### Stage 1 - closed pilot and initial production

- Hetzner CX53 x86, EU region selected after latency tests.
- All production Compose services plus hardened AI overlay on one 32 GB host.
- Hetzner Object Storage for private files and off-host encrypted backups.
- OSM online Street within policy.
- ArcGIS Location Platform online Satellite using the free tier initially.
- TerraLeb-generated OSM offline Street package.
- Offline Satellite feature retained but package unavailable until the written
  imagery licence is attached.
- GEE Limited/pay-as-used or approved non-commercial account.
- Budget: **$53–84/month infrastructure**, plus GEE usage and imagery licensing.

### Stage 2 - measured growth

Trigger a redesign when any two of the following persist for a week, or any one
creates a user-impacting incident:

- memory above 75%;
- CPU saturation/steal above 70% during ordinary use;
- API p95 above the accepted target;
- database disk latency or connection pressure;
- workload queue misses SLA;
- recovery time from a staged failure exceeds the approved target;
- more than one API instance is required;
- map/provider quota reaches 70%;
- GEE spend exceeds the monthly cap;
- an institution requires Bahrain or managed HA.

Then separate database, object storage, workers/AI and API, and choose either
Hetzner dedicated resources or AWS managed HA based on a new measured quote.

## 8. Account-deletion implementation rule

The revised authoritative deletion transaction is:

1. User reauthenticates and submits a request.
2. Protected administrator reviews assignments, official records,
   responsibilities, open cases and any legal hold.
3. The approval dialog lists counts of accepted records that will remain and
   pending/draft records that will be deleted. Nothing destructive is preselected.
4. Required admin/project ownership is transferred.
5. On approval, revoke all sessions and device tokens first.
6. Delete credentials/contact/profile data and every draft, pending/unapproved
   contribution, pending assignment/request owned solely by that user, unapproved
   attachment and affected local encrypted data.
7. Retain accepted GIS plus minimum final approval/source/publication/AI
   provenance, linked to the non-authenticatable tombstone and masked label.
8. Scrub full names/contact identifiers from structured snapshots and queues.
9. Create the backup-expiry record and restricted free-text review task where
   needed.
10. Mark completed only after all stages pass; retries are idempotent.

Regression tests must prove that an approved feature remains geometrically and
relationally unchanged, while a draft and pending-review feature disappear.

## 9. Engineering implementation phases

### Phase 0 - reconcile decisions and preserve the worktree

Changes:

- treat this report and the revised owner form as the selected product direction;
- inventory all current uncommitted work and isolate unrelated user changes;
- do not edit deployed migrations or reset the repository;
- update the implementation plan and baseline test results.

Exit evidence: clean decision diff, migration head/checksums, current test and
performance baseline.

### Phase 1 - correct configuration and release gates

Changes:

- readiness schema supports `approved`, `blocked` and
  `not_in_release_scope` with owner/date/evidence instead of boolean fiction;
- add environment validation for hosting region/provider, AI service enablement,
  project-default AI state, OSM online source, ArcGIS credentials/session mode,
  offline Street package and offline Satellite licence record;
- staging/production examples include all legal/privacy/deletion/export keys;
- production fails if test/demo hosts, credentials or seed modes are present.

Tests: environment matrix, missing-secret failures, release-gate tests and no
secret/token output.

### Phase 2 - AI production overlay

Changes:

- deploy the Python AI service as a hardened internal-only Compose service;
- enable the service at environment level while project records default to false;
- require protected-super-admin authorization for enable/run/resume/cancel,
  validation, publication and unpublication;
- add a strict request allowlist for project GIS/dataset fields;
- exclude account/contact/session/device/notification/draft data;
- configure GEE secret mounts, project/account, callback secret, persistent
  output storage, health, restart/resume and cost/time limits;
- retain model/dataset/run/evaluation/provenance and AI-derived labels;
- keep REST authoritative and publish scoped real-time lifecycle events.

Tests: unauthorized roles, default-off projects, exact input payload, no PII,
GEE outage, callback validation, restart/resume, duplicate callback, cost/time
limit, validation/publication and retraction.

### Phase 3 - online map providers

Changes:

- centralize provider URLs, headers, attribution and credentials;
- remove hard-coded `lb.gov.gis_collector` values and use the final controlled
  Android ID/User-Agent consistently;
- keep OSM Street online with caching, attribution and monitored request rate;
- replace anonymous Esri World Imagery/reference URLs with supported ArcGIS
  Location Platform tile/session access;
- obtain attribution dynamically where required and show it above drawers/sidebars;
- add provider quota, error and fallback metrics without logging user geometry.

Tests: all map screens, drawing/import/export/AI previews, attribution, token
expiry, quota/429, provider outage, map camera preservation and no geometry leak
to the tile provider beyond ordinary tile coordinates.

### Phase 4 - offline Street and Satellite

Changes:

- build/version a Lebanon OSM-derived package from a recorded database extract;
- publish its manifest, checksum, bounds, zoom range, date, attribution and size;
- authenticated resumable download verifies checksum before activation;
- retain existing offline storage/account isolation and safe replacement behavior;
- define an `offlineRightsEvidence` record per source;
- integrate the selected licensed Satellite package through the same provider-
  neutral package interface;
- never route package generation through public OSM or anonymous Esri tile URLs.

Tests: licence gate, interrupted download/resume, corrupt checksum, old version,
storage pressure, account switch, deletion cleanup, map camera and attribution.

### Phase 5 - deletion policy revision

Changes:

- replace eligibility rules that require pending work to finish with an explicit
  protected-admin discard decision;
- calculate accepted-versus-unapproved record counts transactionally;
- delete drafts/pending/unapproved records and preserve only accepted GIS plus
  minimal final provenance;
- keep automatic responsibility release and protected-super-admin prohibition;
- update user/admin wording, audit, backup ledger and mobile cleanup;
- keep execution flag false until migration and all deletion tests pass.

Tests: each role, concurrent review/deletion, accepted/pending/draft mixtures,
attachments/comments, imports/exports/AI, open cases/holds, rollback, retry,
multiple devices and no cross-account local deletion.

### Phase 6 - clean production bootstrap

Changes:

- create a production-only bootstrap that runs migrations and creates only the
  protected super-admin from secret input;
- prohibit dev/test seed commands under `NODE_ENV=production`;
- assert zero non-system users/projects/features/imports/exports/AI runs and zero
  fake acceptances before first launch;
- publish real versioned policies before opening signup.

Tests: empty-database invariant, repeated bootstrap, wrong environment, migration
checksum and protected-super-admin login/rotation.

### Phase 7 - hosting, storage, backups and observability

Changes:

- deploy the chosen host with firewall, automatic security updates, least-
  privilege operator, Docker, TLS and secret files;
- private S3-compatible storage for uploads/exports/AI outputs/off-host backups;
- daily encrypted Postgres backup, object manifest and 35-day lifecycle;
- prove restore to an isolated replacement server;
- set CPU/memory/disk/log/queue/WebSocket/provider/GEE budget alerts;
- keep database, Valkey, ClamAV, AI and monitoring ports private.

Tests: EICAR/scanner, storage authorization, backup restore, disk-full behavior,
certificate renewal, restart, rollback and slow/reconnecting mobile clients.

### Phase 8 - policies, stores, pilot and authorization

Changes:

- insert the real legal operator/contact/provider regions;
- publish approved Arabic/English policies and versioned Terms/AUP acceptance;
- complete Google Data Safety, account deletion, permissions and target-audience
  declarations against the signed AAB;
- run a closed Lebanon pilot on real devices and networks;
- record performance/cost/provider/license/deletion/AI evidence;
- owner and counsel approve exact hashes; only then authorize production.

No application policy, provider or test report may independently set
`productionAuthorized=true`.

## 10. Manual click-by-click deployment - recommended Hetzner path

UI labels may change slightly. Record screenshots/exports without exposing
secrets.

### A. Owner/accounts

1. Decide the exact legal operator and public address/contact.
2. Register/control the production domain.
3. Create an organization-owned password-manager vault and two hardware-backed
   MFA methods for provider/store owner accounts.
4. Create the Hetzner account under the operator, verify billing and enable MFA.
5. Download/accept the actual DPA and record its date/reference.
6. Create or verify an organization Google Play account; pay the $25 fee if not
   already paid; store the receipt.
7. Create the ArcGIS Location Platform/Online account under the operator.
8. Create/approve the GEE project and billing/eligibility under the operator.

### B. Hetzner project and server

1. Hetzner Console → **New project** → name it `terraleb-production`.
2. Project → **Security → SSH keys** → add individual administrator public keys;
   never share one private key.
3. Project → **Firewalls → Create firewall**.
4. Add inbound TCP 80 and 443 from anywhere.
5. Add inbound TCP 22 only from approved administrator IPs or a managed VPN.
6. Do not expose 3000, 5432, 6379, 8000, 9090, 3100 or 3310.
7. Project → **Servers → Add server**.
8. Choose Germany/Nuremberg or Falkenstein after measuring both from Lebanon.
9. Choose Ubuntu LTS x86 and **CX53, 32 GB/320 GB**.
10. Attach the firewall and SSH keys; enable backups; assign the production name.
11. Add a primary IPv4 unless the final network design is IPv6-only and fully
    tested.
12. Create the server and save its IP in the controlled deployment record.

### C. Object storage and DNS

1. Hetzner Console → **Object Storage → Create bucket** in the selected EU
   location.
2. Create separate private prefixes/buckets for uploads, exports, AI outputs and
   encrypted backups where the adapter supports them.
3. Create least-privilege application and backup credentials; store only in the
   secret vault/server secret files.
4. Disable public listing/access; configure the approved 35-day backup lifecycle.
5. DNS provider → create `A` records for the app/API hostname to the server IPv4.
6. Use a low TTL during validation, then increase it after stable production.
7. Confirm DNS resolution from Lebanon before requesting certificates.

### D. Server preparation and deployment

1. SSH as the initial administrator.
2. Apply OS updates, configure timezone/clock sync and automatic security updates.
3. Create a non-root deployment operator with sudo and SSH-key access.
4. Disable password SSH and direct root login only after verifying the new
   operator in a second session.
5. Install the repository-supported Docker Engine and Compose plugin.
6. Configure host firewall to match the Hetzner firewall.
7. Create application, secret, backup and controlled persistent-data directories
   with least privilege.
8. Pull/transfer the immutable release by approved digest/tag; do not build from
   an unreviewed working tree on production.
9. Populate `.env` from `.env.prod.example` using real domains/provider settings.
10. Create every secret file with strong unique values and restrictive
    permissions. Never paste them into tickets, chat, logs or Git.
11. Configure the hardened AI overlay, GEE secret mount and private internal URL.
12. Validate Compose configuration and production environment gates.
13. Start database, run migrations/integrity check, apply restricted runtime
    grants, then start the application/worker/AI/monitoring stack.
14. Bootstrap only the protected super-admin.
15. Verify the clean-production invariant before enabling signup.
16. Request TLS through the existing certificate bootstrap and verify renewal.

### E. ArcGIS online Satellite

1. ArcGIS developer/location console → create the TerraLeb production app.
2. Select the supported basemap privilege and the lowest-risk tile/session usage
   model after load testing.
3. Restrict the credential to the production application/domain/package where
   supported; set a budget/quota alert.
4. Store server credentials only in the vault; use short-lived/session tokens in
   clients where the service design supports them.
5. Replace the legacy raw URLs with supported Basemap Styles/Static Tiles URLs.
6. Test Street/Satellite switching, expiry, rate limit and all required Esri/data
   attribution.

### F. Offline maps

1. Download the approved Lebanon OSM database extract, record URL/date/checksum
   and ODbL version.
2. Generate the agreed zoom-range package on a controlled build host.
3. Create manifest, checksum, bounds, size, version and attribution.
4. Upload to private object storage and register metadata through the authorized
   backend workflow.
5. Test authenticated download/resume and offline Street rendering.
6. Obtain written offline/device redistribution rights for the selected
   Satellite dataset.
7. Record provider, dataset date, area, resolution, attribution, expiry/update,
   MAU/device limits and evidence reference.
8. Only then upload/register the Satellite package and enable its licence flag.

### G. GEE/AI

1. Google Cloud Console → create/select the operator-owned GEE project.
2. Confirm approved non-commercial eligibility or attach billing and choose the
   Limited plan; do not assume free use.
3. Enable required APIs and create the least-privilege service identity.
4. Store the key/credential outside Git and mount it read-only to the AI service.
5. Configure budget alerts and concurrency/run-time/output limits.
6. Confirm new TerraLeb projects store AI disabled.
7. Log in as contributor/admin and prove enable/run controls are absent/rejected.
8. Log in as protected super-admin, enable one test project, run approved synthetic
   GIS, validate output and test publication/retraction.
9. Inspect the outbound payload and logs to prove excluded account/private fields
   never reach AI/GEE.

### H. Legal/store/release

1. Fill the real operator, address, privacy contact, hosting country, Hetzner,
   Firebase, ArcGIS and GEE entries.
2. Obtain counsel approval of the exact Arabic/English document versions.
3. Publish stable HTTPS legal/deletion pages and verify them logged out.
4. Play Console → **App content** → complete Privacy Policy, Data Safety, account
   deletion, target audience 18+, content/reporting and permissions.
5. Play Console → restrict country availability to Lebanon.
6. Upload the signed AAB to closed testing and complete any account-specific
   tester requirement.
7. Run the full backend/mobile/integration/security/performance/migration suite
   and physical-device pilot.
8. Perform backup restore, account deletion, AI, online/offline map, notification,
   real-time and rollback drills.
9. Compare measured monthly costs with budgets and enable alerts at 50%, 70%,
   90% and 100% where supported.
10. Record build/config/document hashes and immutable evidence references.
11. Named owner and counsel sign; then and only then update release readiness and
    authorize production.

## 11. What is settled and what remains genuinely open

### Settled owner policy

- Lebanon-only, Android/web initial release and 18+ users.
- AI deployed, project-default off and protected-super-admin controlled.
- Project GIS-only AI allowlist and no general/cross-project training.
- All online/offline Street/Satellite product modes remain.
- OSM online policy, OSM-derived offline Street and licensed ArcGIS online route.
- Approved GIS/minimal provenance retained after deletion; unfinished work
  deleted on protected-admin approval.
- Production data starts empty.
- Recommended low-cost Hetzner stage followed by measured scaling.

### Still requires an owner purchase/fact or external approval

1. Confirm **Hetzner initial deployment** or choose AWS Bahrain despite the cost.
2. Choose the actual Hetzner EU location after Lebanon latency testing.
3. Name the real legal operator, address and privacy contact.
4. Control the final domain and production Android application ID.
5. Execute provider agreements/DPA and create Play, ArcGIS and GEE accounts.
6. Choose and license the **offline Satellite dataset**. This is the only map mode
   that cannot be made production-ready from the current anonymous URL alone.
7. Confirm GEE eligibility/plan and accept its measured monthly budget.
8. Obtain Lebanese counsel approval of final wording and record the reference.
9. Complete engineering, staging, physical-device, restore and pilot evidence.

Until those acts are complete, it would be inaccurate to say that no blockers
remain. The product policy is now coherent; the remaining blockers are provider
rights/accounts, real operator facts, implementation and evidence.

## 12. Cost recommendation in one line

Start TerraLeb at approximately **$53–84/month plus GEE usage and any offline-
satellite licence** on a 32 GB Hetzner server. Choose AWS Bahrain at approximately
**$296–468/month for one host** or **$510–999/month for managed HA**, plus GEE and
map licensing, only when regional hosting, managed services or institutional
availability requirements justify the difference.

## 13. Authoritative pricing and provider references

- [AWS regional service/instance availability](https://docs.aws.amazon.com/ec2/latest/instancetypes/ec2-instance-regions.html)
- [AWS Price List Bulk API methodology](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/using-the-aws-price-list-bulk-api.html)
- [AWS public IPv4 charge](https://aws.amazon.com/blogs/aws/new-aws-public-ipv4-address-charge-public-ip-insights/)
- [AWS S3 pricing and first 100 GB transfer rule](https://aws.amazon.com/s3/pricing/)
- [AWS SES pricing](https://aws.amazon.com/ses/pricing/)
- [AWS Route 53 pricing](https://aws.amazon.com/route53/pricing/)
- [AWS Support pricing](https://aws.amazon.com/premiumsupport/pricing/)
- [AWS Lightsail pricing](https://aws.amazon.com/lightsail/pricing/)
- [AWS Lightsail region availability announcement/list](https://aws.amazon.com/about-aws/whats-new/2026/06/amazon-lightsail-aws-regions/)
- [Hetzner June 2026 price adjustment](https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/)
- [Hetzner Cloud plans/traffic/volumes](https://www.hetzner.com/cloud/)
- [Hetzner backup pricing](https://www.hetzner.com/cloud/)
- [Hetzner Object Storage pricing](https://www.hetzner.com/storage/object-storage/)
- [DigitalOcean Droplet pricing](https://www.digitalocean.com/pricing/droplets)
- [Google Earth Engine pricing](https://cloud.google.com/earth-engine/pricing)
- [ArcGIS Location Platform pricing](https://location.arcgis.com/pricing/)
- [ArcGIS basemap access and attribution](https://developers.arcgis.com/documentation/mapping-and-location-services/mapping/basemaps/introduction-basemap-styles-service/)
- [Esri website/service terms](https://www.esri.com/en-us/legal/terms/web-site-service)
- [OpenStreetMap copyright/ODbL](https://www.openstreetmap.org/copyright)
- [OpenStreetMap public tile usage policy](https://operations.osmfoundation.org/policies/tiles/)
- [MapTiler online pricing](https://www.maptiler.com/cloud/pricing/)
- [MapTiler on-prem/offline pricing](https://www.maptiler.com/data/pricing/)
- [Google Play developer registration](https://support.google.com/googleplay/android-developer/answer/6112435)

All amounts are estimates, not vendor quotes. Recalculate them in the selected
provider consoles immediately before ordering and store the resulting estimate
with the release evidence.
