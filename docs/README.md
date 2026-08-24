# Monorepo Docs

- `realtime-protocol.md`: versioned invalidation envelope, scopes, reliability,
  authorization, and compatibility.
- `realtime-operations.md`: configuration, deployment, monitoring, rollout,
  rollback, and verification for realtime v2.
- `legal/OWNER_AND_COUNSEL_QUESTIONNAIRE.md`: fill-in answer sheet for the
  unresolved production Privacy Notice, Terms, deletion/attribution, vendor,
  map, AI, store and Lebanese-law decisions.
- `legal/LEGAL_DECISIONS_REQUIRED.md`: authoritative legal release blockers and
  recorded owner decisions.
- `legal/PRIVACY_REQUEST_RUNBOOK.md`: protected request triage, fulfillment,
  evidence and failure handling.
- `legal/CONTENT_MODERATION_RUNBOOK.md`: non-automatic report review and use of
  existing authoritative content workflows.
- `legal/PERSONAL_DATA_EXPORT.md`: isolated encrypted export and download-grant
  design.
- `legal/ACCOUNT_DELETION_AND_PSEUDONYMIZATION.md`: reviewed deletion,
  responsibility transfer, tombstones, masked labels and production gates.
- `FINAL_HANDOVER_AND_DEPLOYMENT_GUIDE.md`: consolidated final handover, deployment, audit, and manual-testing guide.
- `project-plan.md`: phased delivery plan for the delivered non-AI MVP; AI/GEE classification remains future thesis or production integration scope.
- `phase-1/01-scope-baseline.md`: scope baseline for the delivered non-AI MVP.
- `phase-1/02-rbac-matrix.md`: role/permission matrix.
- `phase-1/03-data-dictionary-v0.1.md`: pilot data dictionary draft.
- `phase-1/04-form-schema-versioning.md`: schema change/versioning policy.
- `phase-2/01-migrations-and-seed-strategy.md`: migration and seed execution strategy.
- `phase-2/02-openapi-v0.yaml`: OpenAPI v0 contract for core endpoints.
- `phase-2/03-api-versioning.md`: API versioning policy (`/api/v1` path prefix).
- `phase-9/01-security-reliability-observability.md`: phase 9 security and observability baseline.
- `phase-9/02-secret-rotation-runbook.md`: JWT secret rotation procedure.
- `security/production-infrastructure-observability.md`: current hardened
  production reference, secret/role boundaries, observability, rotation, and
  mandatory external staging gates.
- `predeployment/phase-0-clean-release-baseline.md`: Phase 0 dependency,
  offline-security, toolchain, protected-branch, and baseline-tag evidence.
- `predeployment/phase-5-production-infrastructure-observability.md`: Phase 5
  implementation and verification evidence.
- `predeployment/phase-6-full-release-verification.md`: Phase 6 repository and
  local release-verification evidence, formal Medium-risk decisions, and
  external release gates.
- `predeployment/phase-7-release-candidate-pilot.md`: Phase 7 release-candidate
  supply-chain controls, external-input inventory, staging/pilot evidence
  contract, rollback gates, and current blocking status.
- `phase-9/03-backup-restore-drill.md`: backup/restore drill execution guide.
- `phase-10/01-quality-engineering.md`: quality engineering scope, test matrix, and exit criteria.
- `phase-10/02-release-gates.md`: release gate scripts, CI gate wiring, and performance thresholds.
- `phase-11/01-staging-readiness-and-volume.md`: staging volume seeding and readiness checks.
- `phase-11/02-pilot-rollout-plan.md`: controlled pilot rollout plan and success criteria.
- `phase-11/03-training-materials-and-sops.md`: training packs and SOP framework.
- `phase-11/04-go-live-support-and-release-cycle.md`: go-live/hypercare and monthly release cycle.
- `phase-11/05-operations-checklists.md`: deployment and incident checklists.
- `predeployment/phase-1-data-safety-foundation.md`: authoritative
  pre-deployment environment isolation, data classification, recovery targets,
  verified restore drill, migration, and rollback policy.
- `predeployment/phase-2-private-storage-secure-uploads.md`: authoritative
  private-file delivery, upload quarantine and scanning, storage migration, and
  orphan-reconciliation plan and gate.
- `predeployment/phase-2-storage-reconciliation-runbook.md`: Phase 2C
  checksummed inventory, reviewed migration, rollback, orphan quarantine, and
  failure-recovery procedure.
- `predeployment/phase-3-mobile-data-at-rest.md`: Phase 3 encrypted mobile
  database/photo implementation, recovery behavior, and device-platform gates.
- `predeployment/phase-4-shared-rate-limits-workers.md`: Phase 4 shared limits,
  durable workers, verification evidence, and deployed-replica gates.

Tracked files under `handover/evidence/` are historical verification artifacts from earlier release checks. Treat them as evidence of the run they were captured from, not as current runtime failures unless a current validation report explicitly says so.
