# TerraLeb Phase 0 re-audit and implementation map

Status: engineering baseline; not production authorization or legal advice

Recorded: 2026-08-26

## Repository baseline

- Branch: `handover-ready`
- Baseline commit: `abafdf6`
- Remote state at audit start: synchronized with `origin/handover-ready`
- Latest migration: `0069_prevent_duplicate_open_content_reports.sql`
- Reviewed uncommitted changes preserved: production environment coverage,
  Docker secret wiring, production configuration validation, and the final
  pre-Phase-8 audit documents.
- API type checking: pass.
- API lint: pass.
- Flutter analysis: pass with no issues.
- Static production configuration validation: pass.
- Legal readiness: blocked with 44 findings, as expected.
- Development Docker runtime at audit start: database, Valkey, ClamAV and the
  local research AI service healthy; API unhealthy and workload worker
  restarting because the development database contains a proven pre-release
  checksum for migration 0063 that was not yet listed in the repository's
  source-pinned compatibility register.

## Existing systems that must not be rebuilt

- Privacy requests, correction requests, encrypted access exports, reviewed
  deletion, masked contributor labels and local-device account cleanup.
- Protected-super-admin privacy and moderation queues.
- Content-report handling, notifications and scoped WebSocket/Riverpod updates.
- Local private-storage boundary, upload quarantine, malware scanning,
  canonical `storage://` references and reviewed legacy-file reconciliation.
- Project AI governance, run/review/publication workflows and callbacks.
- Offline project data, drafts, synchronization and the existing resumable tile
  cache user experience.

## Remaining engineering map

| Phase | Existing dependency | Smallest required change | External evidence |
| --- | --- | --- | --- |
| 1 | schema-v1 legal readiness and production env validation | evidence-backed readiness schema v2; complete map/storage/AI/mobile settings and secret checks | owner, counsel and provider evidence remains blocked |
| 2 | local `StorageAdapter` and canonical references | add S3-compatible OCI driver, streaming/materialization boundaries and private-bucket deployment configuration while retaining local development behavior | OCI tenancy, buckets, IAM and restore evidence |
| 3 | direct OSM plus anonymous hard-coded Esri tiles | supported configurable ArcGIS integration, dynamic attribution, provider state/fallback and privacy-safe usage metrics | ArcGIS account, credential and pilot usage evidence |
| 4 | client-side Esri tile caching, disabled by default | authenticated provider-neutral package manifest/download and reproducible Copernicus/OSM package builder | source account, selected scenes, signed manifest and device validation |
| 5 | real AI source at `D:\\AI-ML-pipeline-for-AI-Enhanced-Mobile-GIS`, commit `ed06c63`; development image only | immutable production image input, internal-only hardened overlay, secrets, limits, health and evidence checks | approved image digest, GEE account/plan and selected E4 x86 staging evidence; any later A1 change requires full-stack ARM64 proof |
| 6 | reviewed deletion blocks unfinished work and deletes drafts only | explicit protected-admin discard/transfer decision, locked counts and policy-approved unfinished-record cleanup | retention, masked visibility, photos/location/free-text and backup-age approvals |
| 7 | mature API/mobile test suites and production Compose | clean bootstrap, architecture builds, backup/restore, provider failure, full test/performance evidence | real OCI staging, domain, Firebase, SMTP and signing |
| 8 | fail-closed 44-finding gate | attach immutable evidence and approve only the exact build/config/policy hashes | accountable owner/counsel/store authorization |

## Performance and safety constraints

- Preserve REST as authoritative and do not add polling.
- Stream large objects; do not parse privacy exports or map packages on the UI
  thread.
- Keep private media authorization in the API and never expose public buckets.
- Do not include geometry, coordinates, user IDs or event IDs in metric labels.
- Preserve forms, drafts, map camera, pagination and existing role rules.
- Treat the absence of a comparable production/staging load baseline as an
  evidence blocker; do not fabricate a less-than-five-percent comparison.

## Immediate execution order

1. Restore the local Docker runtime through the documented checksum
   compatibility mechanism and prove migrations/workers healthy.
2. Implement and test readiness schema v2 and production configuration.
3. Add storage and provider integrations behind fail-closed configuration.
4. Reconcile deletion policy with additive migrations and regression tests.
5. Complete all local verification before requesting the first external owner
   action.
