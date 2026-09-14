# TerraLeb DigitalOcean Phases 0–8 execution plan

Status: active finalization plan from 2026-09-05  
Scope: Android and web v1, Lebanon  
Supersedes for hosting: the OCI sections of the earlier Phase 0–8 prompt  
Production authorization: blocked

## Controlling principles

Existing features and workflows remain intact. REST remains authoritative; real-time, offline capture, maps, imports, exports, AI, privacy requests, moderation, correction and reviewed deletion are not rebuilt. A behavior changes only when required for correctness, security, provider compatibility or performance, with a regression test and explicit retest note.

The original 44 findings were a release evidence inventory, not 44 missing screens. Owner product-policy decisions already reduced the live legal gate to 30 honest evidence findings. Engineering closes engineering evidence; real identity, provider contracts, console configuration, live measurements, store declarations and counsel approvals remain blocked until they exist. The gate and legal-draft banner are not bypassed.

## Phase 0 — Re-audit and provider decision

- Preserve the merged production-readiness implementation and clean baseline.
- Record that OCI was abandoned before account/payment/trial/resource creation.
- Independently verify current DigitalOcean price, region, Spaces, backup, firewall and DPA facts.
- Reject 2 GiB for production. Select an 8 GiB/4 vCPU x86 core candidate; allow 4 GiB only as measured constrained staging.
- Keep AI available but separate from the 8 GiB core.

Exit evidence: this plan, `TERRALEB_DIGITALOCEAN_HOSTING_DECISION_V2.md`, clean Git history and official-source references.

## Phase 1 — Production configuration and secrets

- Change production storage validation from OCI Jeddah to DigitalOcean Spaces FRA1.
- Require private, distinct purpose buckets and path-style disabled.
- Require SSE-C for Spaces with separate 32-byte application and backup keys.
- Keep privacy-export and database-backup application encryption independent.
- Rename Docker secret files without committing secret contents.
- Keep production legal drafts, deletion execution and provider integrations fail-closed until their evidence exists.
- Keep the AI container outside the default 8 GiB core profile.

Exit evidence: API typecheck, storage/security tests, Compose rendering and production configuration gate.

## Phase 2 — Infrastructure and private storage

- Validate pinned DigitalOcean Terraform for FRA1, private VPC, exact-CIDR SSH, ports 80/443, assigned Reserved IP, weekly backups, monitoring and a protected core Droplet.
- Create five private, versioned Spaces with `force_destroy=false` and 35-day non-current-version expiry.
- Configure encrypted remote Terraform state before live apply.
- Use a temporary provisioning identity, then revoke it and use separate scoped app/backup keys.
- Verify private access, cross-bucket denial, checksums, range downloads, deletion/lifecycle, encrypted database backup and isolated restore.
- Record CPU, RAM, swap, disk, object operations, DB queries and p50/p95.

No provider apply occurs without an immediately preceding price/plan review and explicit owner approval.

## Phase 3 — Online maps

- Preserve Street and Hybrid views, camera, drawing and overlays.
- Keep OSM interactive use modest, attributed and configurable; never bulk-download public OSM tiles.
- Configure the operator-owned ArcGIS server-side application; no unrestricted secret enters Flutter.
- Exercise expired provider sessions, 401/403/429 responses, exhausted quotas and provider outages, including automatic Street fallback without losing forms or geometry.
- Measure returned tiles per important screen before accepting a billing projection.

Exit evidence: provider agreement/credentials scope, exact attribution, quota alert and 7–30 day staging metric export.

## Phase 4 — Offline map activation

- Do not reactivate the legacy Esri bulk-cache record.
- Acquire Sentinel-2 L2A scenes and a legitimate OSM-derived Lebanon extract.
- Record terms, dates, scene IDs, checksums, cloud filtering, mosaic/clip/reprojection/resampling, tool versions and attribution.
- Build the provider-neutral TerraLeb package, visually inspect it, upload it to private Spaces and activate it through the existing authenticated package workflow.
- Test resumable download, checksum, account isolation, replacement, storage pressure and airplane-mode drawing/forms.

Exit evidence: approved source register, deterministic manifest/checksum and device tests. Until then “offline map not available yet” remains accurate.

## Phase 5 — Production AI

- Preserve project-default-off and protected-super-admin-only control.
- Remediate the located AI source: internal endpoint authentication, no user identifiers, project-scoped diagnostics, pinned base/dependencies, least-privilege data path, object-store outputs, cost/time/concurrency enforcement and callback replay protection.
- Build and scan an immutable x86 image with SBOM/license evidence.
- Deploy it on private on-demand compute only when a run needs it; persist validated artifacts before destroying compute.
- Configure the real GEE project/plan/service identity and quotas without claiming free eligibility incorrectly.
- Test exact inputs, project isolation, restart/resume, cancellation, failure, publication and retraction.

The current 12 GiB limit means the initial AI worker candidate is 16 GiB unless profiling proves 8 GiB safe. A stopped Droplet remains billable; the orchestrated worker must be destroyed after reconciliation.

## Phase 6 — Policy/runtime reconciliation

- Preserve existing reviewed deletion, export, correction and moderation systems.
- Verify approved retention and deletion behavior in DigitalOcean storage versioning/backups.
- Prove sessions/devices are revoked, local data is account-scoped, direct identifiers and pending/unapproved records are erased, accepted GIS/minimum provenance remains masked as approved, and deleted data cannot be restored active.
- Verify legal pages contain only true provider/operator facts.

The owner-approved schedule and product rules are not a substitute for counsel approval of legal bases and final public wording.

## Phase 7 — Staging and release engineering

- Bootstrap an empty staging database with only the protected super administrator.
- Deploy core Compose, TLS, Nginx/WebSocket, workers, Spaces and monitoring in FRA1.
- Run full API, Flutter, migration, security, release-image, performance and accessibility gates.
- Run Android/web release builds, Firebase/push, maps, offline package, privacy export, correction, moderation, deletion and two-session real-time tests.
- Exercise disk full, provider outage, reconnect storm, backup/restore and rollback.
- Reject unexplained performance regression over 5% and record real cost/usage.

## Phase 8 — Assisted external evidence and authorization

Codex performs safe repository/browser work and asks the owner for exactly one small action whenever private entry or consent is required. The owner never sends passwords, cards, tokens, private keys, recovery codes or MFA codes in chat. After `continue`, Codex verifies the result before asking for the next action.

External evidence families are:

1. DigitalOcean account/team/MFA, provider terms/DPA, FRA1 and spend alerts.
2. Real operator/controller, public address/contact and production domain.
3. Terraform plan/apply, scoped Spaces keys, SSE-C custody and restore evidence.
4. ArcGIS online application, terms, attribution, quota and live tile metrics.
5. Copernicus/OSM source evidence and offline package approval.
6. AI immutable image, GEE registration/plan, roles, quotas and run evidence.
7. Final Android ID/signing, Firebase and Google Play organization/declarations.
8. SMTP sender/domain and delivery evidence.
9. Counsel review of Law 81 formalities, provider transfers, retention/legal bases, governing law/disputes and exact Arabic/English document hashes.
10. Exact-build release-owner authorization after every applicable item passes.

The step-by-step source of truth is `MANUAL_ACTIONS_REQUIRED_FOR_PHASE_8.md`; every verified action is recorded in `docs/predeployment/MANUAL_SETUP_PROGRESS.md`.

## Expected behavior changes

- Production artifacts move from the uncreated OCI design to private DigitalOcean Spaces using SSE-C; local development remains local.
- Production hosting candidate changes from OCI Jeddah 32 GiB to DigitalOcean Frankfurt 8 GiB core, with AI separated.
- The default production Compose no longer tries to co-host the 12 GiB AI service on the core; AI product permissions and workflows remain unchanged.
- Draft legal text names DigitalOcean Frankfurt only as a blocked candidate until real evidence exists.

No business role, form field, project visibility, map mode, offline collection, import/export, review, privacy request, deletion, notification or real-time workflow is intentionally removed or weakened.
