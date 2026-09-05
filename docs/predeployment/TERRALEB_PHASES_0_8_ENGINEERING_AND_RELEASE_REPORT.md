# TerraLeb Phases 0–8 engineering and release report

Report date: 2026-09-05
Release scope: Android and web v1, Lebanon
Repository baseline: `handover-ready` at `abafdf6`, with all reviewed pre-existing worktree changes preserved
Current production authorization: **blocked**

This is an engineering/evidence report, not a legal opinion. Passing the engineering checks does not establish legal compliance. Final legal bases, retention periods, policies, Law 81 conclusions and release authorization require the designated legal owner and qualified Lebanese counsel.

## 1. Architecture summary

TerraLeb keeps its existing Node/Express/PostgreSQL/Valkey/WebSocket backend, Flutter/Riverpod client, REST authority, offline sync, protected-super-admin controls, privacy workflows and business rules.

Production integration adds:

- evidence-backed legal readiness with fail-closed `approved`, `blocked` and narrowly permitted `not_in_release_scope` states;
- Docker secret-file validation and complete production environment coverage;
- OCI Jeddah OpenTofu infrastructure, now defaulting to E4 Flex x86 4 OCPU/32 GB because the pinned PostGIS image has no ARM64 manifest;
- private S3-compatible OCI object storage, streaming/checksums/validation and a separate encrypted database-backup identity/workflow;
- server-side ArcGIS OAuth tile proxy, dynamic attribution, quota/rate limits, provider switch, metrics and Street fallback;
- provider-neutral, authenticated and resumable offline-package delivery plus a deterministic Copernicus Sentinel-2/OSM-derived builder;
- hardened TerraLeb-to-AI boundary, project data allowlist, internal secret, cost/concurrency limits and digest-required internal Compose service;
- an additive reconciliation of reviewed deletion so protected admins can explicitly transfer/release responsibility or discard unapproved work without a preselected destructive choice;
- dependency/SBOM/license inventory generation in the release-candidate pipeline.

No SignalR/.NET service, replacement REST authority, timer polling dependency, public object bucket or client-shipped map/AI secret was introduced.

## 2. Files changed

The worktree was intentionally not reset or committed automatically. The review set is:

### Root, CI, release and configuration

`.env.example`, `.env.prod.example`, `.gitignore`, `.github/workflows/release-candidate.yml`, `compose.prod.yml`, `secrets/README.md`, `scripts/release-candidate.js`, `scripts/release-candidate.test.js`, `scripts/verify-legal-readiness.js`, `scripts/verify-legal-readiness.test.js`, `scripts/verify-production-config.js`, `scripts/generate-dependency-license-report.js`, `scripts/generate-dependency-license-report.test.js`.

### API

`apps/api/.env.example`, `apps/api/Dockerfile`, `apps/api/docker/entrypoint.sh`, `apps/api/package.json`, `apps/api/package-lock.json`, `apps/api/docs/openapi.yaml`, `apps/api/docs/legal/release-readiness.json`, `apps/api/scripts/check-openapi.js`, `apps/api/src/app.ts`, `apps/api/src/config/env.ts`, `apps/api/src/db/seedStaging.ts`, `apps/api/src/controllers/ai.controller.ts`, `export.controller.ts`, `import.controller.ts`, `mapProvider.controller.ts`, `misc.controller.ts`, `photo.controller.ts`, `privacy.controller.ts`, `privateMedia.controller.ts`, `project.controller.ts`, `apps/api/src/jobs/publishOfflineMapPackage.ts`, `runDatabaseBackup.ts`, `apps/api/src/middleware/observability.ts`, `validation.ts`, `workloadRateLimit.ts`, `apps/api/src/routes/index.ts`, `privacy.routes.ts`, `project.routes.ts`, `apps/api/src/services/accountDeletion.service.ts`, `aiServerClient.service.ts`, `arcgisMapProvider.service.ts`, `databaseBackup.service.ts`, `featurePhotoSecurity.service.ts`, `mapProviderMetrics.ts`, `offlineMapPackage.service.ts`, `privacyExport.service.ts`, `secureImageStorage.service.ts`, `sharedRateLimit.service.ts`, `storageAdapter.service.ts`.

### API tests

`apps/api/test/ai.endpoints.test.js`, `databaseBackup.test.js`, `mapProvider.service.test.js`, `migration.integrity.test.js`, `offlineMapPackage.test.js`, `phase5.production-security.test.js`, `privacyExecution.integration.test.js`, `project.workflow-access.test.js`, `storageAdapter.test.js`, `storageAdapter.s3.test.js`.

### Flutter application

`apps/mobile/pubspec.yaml`, `pubspec.lock`, `lib/core/config/app_env.dart`, `lib/core/offline/local_models.dart`, `local_store_mobile.dart`, `lib/core/providers/providers.dart`, `lib/features/admin/data/api_admin_repository.dart`, `domain/admin_models.dart`, `domain/admin_repository.dart`, `lib/features/ai/presentation/screens/project_ai_screen.dart`, `lib/features/exports/presentation/screens/exports_dashboard_screen.dart`, `lib/features/imports/presentation/screens/import_detail_screen.dart`, `import_map_screen.dart`, `lib/features/legal/data/api_legal_repository.dart`, `domain/legal_repository.dart`, `presentation/screens/privacy_moderation_admin_screen.dart`, `lib/features/map/data/api_map_repository.dart`, `offline_project_download_service.dart`, `offline_tile_cache_manager.dart`, `lib/features/map/domain/app_tile_provider.dart`, `lebanon_map.dart`, `lib/features/map/presentation/screens/add_feature_screen.dart`, `map_screen.dart`, `widgets/basemap_attribution.dart`, `project_quick_map_card.dart`, `lib/features/profile/presentation/screens/profile_screen.dart`, `lib/features/projects/data/api_projects_repository.dart`.

### Flutter tests

`apps/mobile/test/features/exports/presentation/exports_dashboard_screen_test.dart`, `features/legal/privacy_moderation_admin_screen_test.dart`, `features/map/data/offline_package_download_test.dart`, `offline_project_download_service_test.dart`, `features/map/domain/app_tile_provider_test.dart`, `features/map/presentation/basemap_attribution_test.dart`, `features/projects/data/api_projects_repository_test.dart`.

### Infrastructure and documentation

`infra/migrations/checksum-compatibility.json`, migrations 0070–0072 below, `infra/oci/terraform/**`, `infra/offline-map/**`, `docs/legal/ACCOUNT_DELETION_AND_PSEUDONYMIZATION.md`, `PRIVACY_REQUEST_RUNBOOK.md`, `TERRALEB_MAP_AND_REGIONAL_HOSTING_DECISION.md`, `TERRALEB_REVISED_OWNER_POLICY_COST_AND_DEPLOYMENT_PLAN.md`, `MANUAL_ACTIONS_REQUIRED_FOR_PHASE_8.md`, `TERRALEB_FINAL_PRE_PHASE_8_REAUDIT_AND_EXECUTION_PROMPT.md`, `docs/predeployment/MANUAL_SETUP_PROGRESS.md`, `PHASE_0_REAUDIT_AND_IMPLEMENTATION_MAP.md`, `PHASE_7_ENGINEERING_VERIFICATION.md`, `phase-2-oci-object-storage-and-backup-runbook.md`, `phase-3-4-online-and-offline-maps.md`, `phase-5-production-ai.md`, and this report.

## 3. Migrations added

| Migration | Purpose |
|---|---|
| `0070_map_provider_and_offline_package_governance.sql` | Provider-neutral package metadata/provenance/licence approvals and production map-provider governance. |
| `0071_account_deletion_owner_decisions.sql` | Explicit discard/transfer decisions, locked eligibility evidence and deletion cleanup structures. |
| `0072_account_deletion_completion_guard.sql` | Database-level completion guard so deletion cannot report completion before mandatory cleanup succeeds. |

The full chain and migration-integrity checks pass. Existing deployed migrations were not edited. The documented checksum compatibility register was extended for proven historical pre-release database checksums instead of weakening integrity checks.

## 4. All 44 readiness findings

`productionAuthorization` is a separate aggregate gate and remains blocked. Of
the 44 findings below, 12 owner-policy decisions are approved with immutable
repository evidence, 29 remain blocked on external/provider/staging/counsel
evidence, and three are evidenced v1 scope exclusions. The verifier prints 30
blocked gate items because it also includes aggregate production authorization.

| # | Finding | Status | Current evidence or exact blocker |
|---:|---|---|---|
| 1 | Counsel approval | Blocked | No dated approval for exact behavior/policy/build hashes. |
| 2 | Legal operator/controller | Blocked | Real identity/address not supplied. |
| 3 | Controller/processor roles | Approved (owner operating model) | Operator controls accounts/security; project institutions control/authorize project purpose/review/retention/publication; actual named agreements remain separately blocked. |
| 4 | Target territories/distribution | Approved | Lebanon-only Android/authenticated-web v1; iOS public release deferred. |
| 5 | Minimum age/minors | Approved | 18+; minors are not permitted; no birth date is collected solely to prove age. |
| 6 | Privacy contact | Blocked | Public operator-controlled contact not supplied. |
| 7 | Hosting regions/subprocessors | Blocked | OCI Jeddah design exists; real tenancy/provider/DPA evidence absent. |
| 8 | Retention matrix | Approved (owner schedule) | Exact operational schedule adopted; cleanup/staging and counsel evidence remain separately blocked. |
| 9 | Retained institutional-record basis | Approved (owner purpose) | Only accepted GIS/minimum institutional provenance; final lawful-basis conclusion remains counsel-gated. |
| 10 | Masked contributor display | Approved | Internal authorized masked label; public/general output uses `Contributor`; no public UUID. |
| 11 | Photos/location/free-text treatment | Approved | Accepted-record sensitivity/retention rules, shorter private/rejected deletion and restricted free-text review adopted. |
| 12 | Backup ageing | Approved | 35-day natural expiry plus deletion-ledger restore suppression. |
| 13 | Contributor/deletion notices | Approved (owner wording baseline) | Exact public clauses still require operator facts, translation and counsel approval. |
| 14 | Map/offline rights | Blocked | Technical provider separation exists; exact account/source rights evidence absent. |
| 15 | GIS ownership/publication | Approved (owner policy) | Limited operational licence and separate institutional publication authority adopted; actual source/institution rights remain blocked. |
| 16 | AI training/publication | Approved | AI stays per-project default-off/protected-admin controlled; allowlisted project GIS only; no general/cross-project training. |
| 17 | Governing law/disputes | Blocked | Requires counsel wording. |
| 18 | Required languages | Approved (scope) | Arabic and English selected; final translation and counsel-approved documents remain blocked. |
| 19 | Lebanon Law 81 formalities | Blocked | Requires counsel review against authoritative Arabic source and real data/operator facts. |
| 20 | Apple approval | Not in release scope | Android/web v1 excludes iOS public release; immutable controlling-prompt evidence recorded. |
| 21 | Google Play approval | Blocked | Organization/account/declarations/exact AAB evidence absent. |
| 22 | Account deletion verified | Blocked | Engineering tests pass; production approvals and provider-backed staging evidence absent. |
| 23 | iOS purpose strings | Not in release scope | iOS not distributed in v1; tracked `Info.plist` hash recorded. |
| 24 | Privacy manifest/SDK inventory | Blocked | Dependency inventory generated; security owner/store review absent. |
| 25 | Production identifiers | Blocked | Final domain/application ID/Firebase/signing absent. |
| 26 | Privacy-rights fulfillment | Blocked | Workflows exist; production operational/legal-owner evidence absent. |
| 27 | Retention automation | Blocked | Cleanup/expiry paths exist; approved periods and staging execution absent. |
| 28 | Notification privacy | Blocked | Privacy-preserving behavior exists; Firebase/device/staging verification absent. |
| 29 | UGC moderation | Blocked | Protected workflow exists; moderation owner operational evidence absent. |
| 30 | Accessibility | Blocked | local widget/text-scaling checks pass; owner/device matrix approval absent. |
| 31 | Software licences/SBOM | Blocked | SBOM/license report generation exists; 292 npm + 136 Flutter entries require exact-release legal/security review. |
| 32 | Import provenance | Blocked | Provenance controls exist; GIS/legal approval and exact source pilot evidence absent. |
| 33 | OSM online | Blocked | Visible attribution/config/cache-safe interactive path exists; final GIS/legal review and production measurement absent. |
| 34 | Esri online licence | Blocked | OAuth proxy/limits/fallback exist; operator account/terms/credentials/live usage absent. |
| 35 | Offline source rights | Blocked | Deterministic builder exists; exact Copernicus scenes, OSM extract and signed licence record absent. |
| 36 | Attribution | Blocked | local UI/API tests pass; exact live provider response and screen/export review absent. |
| 37 | Esri offline redistribution | Not in release scope | Client Esri bulk cache path removed from v1; provider-neutral package boundary hash recorded. |
| 38 | Privacy document | Blocked | Draft/version infrastructure exists; final facts/translation/counsel hash absent. |
| 39 | Terms | Blocked | Same blocker. |
| 40 | Acceptable Use | Blocked | Same blocker. |
| 41 | Important Notices | Blocked | Same blocker. |
| 42 | Account Deletion notice | Blocked | Behavior stable; approved exact wording absent. |
| 43 | Subprocessor notice | Blocked | Real OCI/ArcGIS/Google/SMTP/AI provider facts absent. |
| 44 | Open-source notice | Blocked | Inventory complete; exact-release licence review and approved notice absent. |

Owner-policy records were approved only within their stated scope and tied to
`TERRALEB_OWNER_POLICY_DECISION_RECORD_V1.md` or `RETENTION_MATRIX.md` hashes.
No external fact, provider right, counsel conclusion, public document, store
submission, staging result, or production authorization was fabricated or
downgraded.

## 5. Engineering findings closed

- Production environment parity, secret-file wiring and fail-closed configuration validation.
- Evidence-format schema and tests preventing omitted findings, placeholders or unsupported exclusions.
- Private object-storage abstraction and encrypted backup implementation.
- Anonymous production Esri use removed; server-side operator credential boundary and fallback implemented.
- Esri offline bulk caching removed from release scope without removing offline capability; provider-neutral package workflow implemented.
- AI boundary excludes actor/contact/profile/session data and limits protected-admin/project/run behavior.
- Deletion policy mismatch resolved with explicit protected-admin decisions and durable completion guard.
- Full Flutter regression suite, API build/lint/type/OpenAPI/migrations/dependency audit, focused security/performance checks, Docker worker/health/Nginx/WebSocket checks, release/static gates and architecture proof completed locally.

“Closed” here means the engineering defect/control is implemented. It does not convert the related owner/provider/counsel finding to approved.

## 6. External findings awaiting evidence

The interactive source of truth is `docs/legal/MANUAL_ACTIONS_REQUIRED_FOR_PHASE_8.md`; progress is in `docs/predeployment/MANUAL_SETUP_PROGRESS.md`. Owner decisions for retention/deletion, GIS/AI, minors and territory are complete. Remaining evidence families are OCI/hosting, operator/domain/contact, ArcGIS, Copernicus/OSM, production AI/GEE, Firebase/Play/signing, SMTP, implemented retention/deletion staging proof, institution/source contracts, Law 81/counsel, bilingual final policies, staging measurements and exact-build authorization.

Codex will request one action at a time and verify each `continue`; the owner is not expected to perform the register alone.

## 7. Map providers and quota projection

Street preserves the OSM view, visible attribution, configurable URL and normal interactive use. The public OSM tile service is never used to make offline packages.

Hybrid preserves imagery, labels, overlays, drawing and camera. Production traffic uses an authenticated backend ArcGIS proxy. It handles token expiry, 401/403/429, quota and outage and falls back to Street with a brief notice while preserving forms and geometry. Credentials remain server-side.

The current ArcGIS static-basemap model advertises 2,000,000 returned tiles/month free and USD 0.15/1,000 above the allowance. Billing is based on returned tiles, not whether navigation stays inside Lebanon. The exact projection is intentionally unresolved until staging supplies real counts from all map screens. Formula: `max(0, returned_tiles - 2,000,000) / 1,000 × 0.15`.

## 8. Offline source/processing/licence evidence

The pipeline accepts Sentinel-2 L2A true-colour source products, cloud/shadow rules, mosaic/clipping, reprojection/resampling, exact tool versions, zoom range, OSM-derived labels from a legitimate extract, source IDs/dates/checksums/terms, package version/checksum and attribution. The builder is deterministic and tests pass 2/2.

No scene or extract has been selected/downloaded and no package has been published, so source rights remain blocked. The initial product is a 10 m orientation basemap, not cadastral, survey, parcel, building-grade or emergency-navigation imagery.

## 9. Hosting/storage and estimated cost

OCI E4 Flex x86 is selected because the full ARM gate failed at the pinned PostGIS image. The expected infrastructure baseline is USD 160–180/month before tax and optional provider costs. ArcGIS can remain at USD 0 within its current allowance; Earth Engine, SMTP, domain, counsel and any overages are separate. No external resource/purchase has occurred.

All application artifacts use the private storage boundary: photos/uploads, imports, ordinary exports, application-encrypted privacy exports, AI outputs and offline packages. PostgreSQL remains on block storage; encrypted backups go to the isolated backup bucket/archive process. Real IAM and restore evidence awaits OCI.

## 10. AI deployment and data allowlist

AI remains available but disabled by default for every project. Only the protected super administrator can enable project AI and control runs/datasets/review/publication/retraction. TerraLeb sends allowlisted project/run IDs, approved AOI/feature geometry, approved labels/samples/imagery and bounded model parameters. It excludes names, emails, phones, credentials, sessions, device tokens, notifications, profiles, private/unsynchronized drafts, unrelated projects and arbitrary free text.

The located historical AI source is real but not production-safe unchanged. Its unauthenticated endpoints, broad database/output behavior, actor ID export, mutable image and missing replay/object-store controls are documented in `phase-5-production-ai.md`. Production remains blocked until a remediated immutable x86 image digest and Earth Engine evidence exist.

## 11. Account deletion

All supported roles except the protected super administrator may request reviewed asynchronous deletion. Deactivation remains contributor-only and separate. The protected administrator must explicitly select responsibility resolution and unfinished-work treatment; no destructive choice is preselected. Eligibility is recalculated under lock at execution.

Deleted: credentials, direct contacts/profile values, sessions/device tokens/destinations, private drafts, approved-to-discard unapproved/pending data and unnecessary attachments, structured direct-identity snapshots and local account data for that account. Durable object deletion must finish before completion.

Retained when policy approval exists: accepted GIS geometry and minimum institutional provenance under the once-generated masked contributor label/tombstone. The mask is pseudonymous, not anonymous. Known free-text identifiers create restricted review work instead of destructive arbitrary text rewriting. Backup expiry is scheduled. Production execution remains fail-closed until required immutable approval references exist.

## 12. Security and authorization controls

- protected-super-admin authorization remains server-side;
- provider, storage, AI and backup credentials are secret-file mounted and absent from Flutter/events/logs;
- private buckets and bounded/validated streaming responses;
- account/project/object IDOR checks remain authoritative;
- AI/map events and metrics avoid PII/coordinates/high-cardinality identifiers;
- rate, size, quota, timeout, replay/idempotency and cleanup guards;
- deletion completion database guard and early session/device revocation;
- production legal drafts and placeholder configuration fail closed;
- release-candidate evidence binds exact build/config/policy hashes.

## 13. Performance before/after

The 2026-09-05 local performance suites passed: bounding-box 69 ms, export 482 ms, concurrent workload 3,769 ms and worker restart 989 ms under their existing thresholds. A prior post-suite development Nginx smoke sample measured `/health` p50/p95 at 5.12/15.88 ms across 100 sequential requests and `/ready` at 5.79/7.15 ms across 50 requests. Full Flutter coverage passed 426/426 at 52.25% line coverage. Map invalidation is scoped; repeated provider events are not used to refresh unrelated workflows. Object paths stream and offline extraction uses an isolate.

There is no comparable production or OCI staging baseline. Therefore no truthful p50/p95, tile/session or <=5% before/after claim can yet be made. Staging must record API p50/p95, DB query counts, object calls/bytes, CPU/memory, worker queue, WebSocket latency/reconnect and map returned tiles under equivalent load.

## 14. Tests and exact results

See `PHASE_7_ENGINEERING_VERIFICATION.md` for the command matrix. On 2026-09-05 the complete API CI gate passed after applying all 73 migrations to an isolated clean database; API lint/typecheck/build and the 182-operation OpenAPI check passed; all three performance suites passed; npm audit and OSV reported zero dependency findings; Flutter analyze was clean and 426/426 coverage tests passed at 52.25%; production runtime/config tests passed; a 251-commit Gitleaks scan found no secrets; and the rebuilt API and monitoring release images had zero unsuppressed high/critical Trivy findings. The legal evidence-model tests pass and the live gate remains intentionally blocked on 30 items, including aggregate authorization.

## 15. Manual click-by-click actions

Exact guarded steps, effects, costs, evidence and rerun gates are in `docs/legal/MANUAL_ACTIONS_REQUIRED_FOR_PHASE_8.md`. The current interaction starts with OCI sign-in/tenancy-region verification. No paid apply, domain/DNS change, legal publication, store submission or production-data operation occurs without immediate explicit approval.

## 16. Deployment and rollback

1. Complete OCI/provider/operator facts without approving unresolved legal findings.
2. Review `tofu plan` and live price; obtain explicit approval; apply only the reviewed plan.
3. Install secret files out of Git, render Compose and bootstrap an empty staging database.
4. Deploy immutable API/web/AI images, run migrations, health/TLS/WebSocket/storage/worker smoke checks.
5. Generate and validate an encrypted backup by isolated restore before accepting traffic.
6. Configure ArcGIS/Copernicus package/AI/Firebase/SMTP one at a time and run their failure-path tests.
7. Run full functional, accessibility, performance, security and owner retest matrix; preserve evidence.
8. Finalize/approve bilingual policy hashes, Play declarations and exact-build authorization.
9. Pilot/closed rollout with monitoring before production expansion.

Rollback uses prior immutable container/web/package versions, the last reviewed object versions and a new isolated restored database when recovery is needed. Provider switches disable Hybrid/AI safely. Keep deletion disabled unless all required approvals exist. Never use Terraform destroy, rewrite backups, reset migrations or expose public buckets as rollback methods.

## 17. Existing feature or behavior changes

### Production Hybrid provider

- Previous: anonymous hard-coded legacy Esri URLs could be called directly.
- New: production uses operator-authenticated server proxy, dynamic attribution, quotas and Street fallback.
- Necessary because: anonymous reachability is not a production licence/security boundary; secrets cannot ship to Flutter.
- Without it: credential leakage, uncontrolled quota, brittle outages and missing exact attribution.
- Compatibility: Street/Hybrid, overlays, drawing, camera and unsaved forms remain; only outage behavior becomes explicit.
- Tests: API provider service, Flutter tile/attribution/fallback, OpenAPI and Nginx checks.
- Owner retest: every Street/Hybrid screen, drawing/form preservation, fallback notice, attribution, expiry/quota/outage.
- Deployment/training: configure server credentials/limits; no normal-user training beyond the brief fallback notice.

### Offline Hybrid source

- Previous: legacy Esri client tile caching path existed but was unsuitable for production redistribution.
- New: authenticated provider-neutral TerraLeb package; Esri offline redistribution excluded from v1.
- Necessary because: online tile access does not establish bulk/offline redistribution rights.
- Without it: licence/provider-policy exposure and non-reproducible packages.
- Compatibility: offline download progress/resume/checksum/account isolation/forms/camera/drawing remain.
- Tests: backend/package/storage tests, Flutter package/download tests, Python builder 2/2.
- Owner retest: interrupted download, replacement, airplane mode, account switch, storage pressure, notice/attribution.
- Deployment/training: users see a brief Sentinel source/date/10 m orientation notice.

### Account-deletion unfinished work

- Previous: contributors with unfinished responsibilities were blocked and the admin could not safely authorize owner-requested discard/transfer.
- New: protected admin explicitly selects transfer/release and `require_resolution` or `discard_unapproved`; no option is preselected.
- Necessary because: owner policy permits reviewed deletion while relational integrity and accepted records must remain safe.
- Without it: deletion stays permanently blocked or unfinished records are discarded ambiguously.
- Compatibility: protected super admin remains non-deletable; deactivation stays separate; accepted GIS remains masked; normal project workflows unchanged.
- Tests: API privacy execution 5/5, Flutter protected-admin workspace 10/10, migration guards and full Flutter regression.
- Owner retest: every role, responsibility transfer/discard, failure/retry/session revocation/local cleanup/masked accepted record.
- Deployment/training: protected admins must understand the two explicit decisions; production remains disabled until policy references are approved.

### AI production boundary

- Previous: the TerraLeb request included an initiating user ID and lacked the completed production internal-service/cost boundary.
- New: actor ID/secret are excluded from persisted/outbound payloads; internal auth and limits are required; project control remains protected-super-admin only.
- Necessary because: AI needs no account identity and an internal service must not trust unauthenticated requests.
- Without it: unnecessary data disclosure and unauthorized/cost-unbounded runs.
- Compatibility: AI stays available, per-project default-off, and existing review/publication controls remain.
- Tests: complete AI endpoint/security regression 37/37 plus configuration checks.
- Owner retest: enable/run/cancel/retry/review/publish/retract, provider failure and unrelated-project isolation.
- Deployment/training: immutable remediated AI image/GEE setup required; no contributor workflow change.

### Production file persistence

- Previous: the local storage adapter and host volumes were the main runtime persistence path.
- New: production stores growing artifacts in private OCI-compatible buckets; local remains the development default.
- Necessary because: single-host files are not durable/scalable enough for production recovery.
- Without it: host loss, disk pressure and weak backup/reconciliation behavior.
- Compatibility: API references and user workflows remain; privacy exports remain application-encrypted and reauthenticated.
- Tests: local/S3 adapters, private authorization, backup and service regressions; live OCI restore remains pending.
- Owner retest: photo/import/export/privacy export/offline package/AI artifact flows and expiry.
- Deployment/training: operations receives bucket/IAM/backup runbooks; users see no intended change.

### Production host architecture

- Previous plan: A1 ARM64 preferred if the full stack passed.
- New: E4 x86 is the release default.
- Necessary because: the exact pinned production PostGIS image has no ARM64 manifest.
- Without it: production database container cannot start.
- Compatibility: no business/UI behavior changes; monthly cost is higher.
- Tests: actual API ARM build/runtime plus PostGIS manifest failure and successful x86 database build.
- Owner retest: staging stack/bootstrap/backup/restore and performance.
- Deployment/training: review the USD 160–180/month estimate before apply.

No other existing business feature or workflow was intentionally changed. Remaining changes were limited to production integration, real-time correctness, privacy execution, provider compliance, security, observability and performance.

## Owner retest matrix

- Signup: legal acceptance link/unchecked checkbox/disabled submission/alert.
- Login: logged-out Privacy/Terms; unverified-account verification navigation/back/logout/cleared fields.
- Permissions: notification explanation/preview toggle; camera requested only on add/take photo.
- Profile: concise legal/privacy card; deactivation/deletion separation.
- Privacy/moderation: own request status, protected-super-admin queues, correction, access export, content reports/actions.
- Deletion: viewer/contributor/admin/protected-super-admin; eligibility, explicit discard/transfer, masked retained GIS, session/device/local cleanup and retries.
- Maps: Street/Hybrid on every map/card/import/feature screen; attribution, camera/drawing/forms, fallback and no geometry loss.
- Offline: download/progress/interruption/checksum/replacement/storage pressure/account isolation/airplane mode/source notice.
- Workflow: features/photos/comments/submission/review, imports, exports and AI enable/run/review/publish/retract.
- Real-time: two sessions/same account/unrelated projects; logout/revocation; no polling dependency or unrelated provider refresh.
- UI/stability: all dialogs at phone/tablet/desktop/text scale; no Riverpod build/dispose errors; no unsaved input, pagination, scroll or camera loss.
