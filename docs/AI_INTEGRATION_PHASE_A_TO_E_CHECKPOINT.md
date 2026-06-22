# AI Integration Phase A to E Checkpoint

## Purpose

This checkpoint summarizes the AI app integration work completed from Phase A through Phase E. It is a report-only checkpoint before Phase F. It does not add new app code, run GEE, train models, add Redis, merge branches, or modify runtime database state.

## Branch Stack

The AI integration work is stacked sequentially:

1. `handover-ready`
2. `feature/ai-integration-schema-phase-a`
3. `feature/ai-integration-backend-phase-b`
4. `feature/ai-integration-mobile-phase-c`
5. `feature/ai-integration-worker-phase-d`
6. `feature/ai-integration-pipeline-bridge-phase-e`

Phase E is the current tip branch. It contains the work from Phases A through D.

## What Is Implemented

### Phase A: Schema Foundation

Phase A added the database foundation for AI integration:

- AI-specific tables for project settings, runs, metrics, output layers, class statistics, uncertainty areas, run logs, and review decisions.
- Source/provenance support on `spatial_feature` so human/imported field data can be distinguished from other sources.
- A clear separation between approved field data and AI outputs.
- AI predictions are not inserted into `spatial_feature`.
- AI output metadata is stored in dedicated AI tables and remains reviewable before publishing.

### Phase B: Backend AI Endpoints

Phase B added backend API foundations without executing real AI jobs:

- AI readiness endpoint for project-approved data.
- AI settings endpoints for project AI configuration.
- AI run create/list/detail endpoints.
- AI metrics, layers, and logs read endpoints.
- RBAC protection so AI management remains limited to authorized admin-level users.
- OpenAPI coverage for the new backend AI endpoints.

### Phase C: Mobile UI Foundation

Phase C added the super-admin-facing AI workspace:

- Super-admin AI workspace route.
- Readiness UI.
- Settings UI.
- Runs UI.
- Clean classifier field behavior based on project schema and useful label candidates.
- No claim that real AI is running when only metadata or mock execution exists.
- Viewer/contributor access remains hidden or denied.

### Phase D: Worker Skeleton

Phase D added a safe worker skeleton:

- Mock worker execution path.
- Controlled status transitions.
- `ai_run_log` progress logging.
- Concurrency safety using queued-run claiming with row locking.
- No Python, GEE, feature extraction, training, classification, or app DB output insertion.

### Phase E: Safe Pipeline Bridge

Phase E connected the backend worker to the external AI pipeline in a safe, limited mode:

- AI pipeline configuration, disabled by default.
- Safe adapter using argument arrays instead of shell command strings.
- Config check.
- AI dry-run.
- Project readiness/probe command.
- Local-only ground truth export mode.
- Sanitized logs and timeout handling.
- Worker metadata updates for safe command results and output paths.
- No full GEE feature extraction.
- No model training.
- No Lebanon classification.
- No vectorization or insertion into app feature data.

## Intentionally Not Implemented Yet

The following items are intentionally not part of Phases A through E:

- Real GEE feature extraction from the worker.
- Full model training from the worker.
- National classification.
- AI map layer display.
- Confidence or uncertainty map display.
- Publishing AI layers to viewers.
- Redis or queue infrastructure.
- Production AI scheduling.
- Production background scaling.

## Current Safety Guarantees

Current safety boundaries are:

- AI predictions are not inserted into `spatial_feature`.
- Approved human/imported field data remains separate from AI outputs.
- Raw AI outputs remain outside app-approved field data.
- Secrets, `.env` values, GEE keys, raw data, and generated outputs are not committed.
- Worker commands are limited to the Phase E allowlist.
- Full GEE, training, classification, and vectorization commands are blocked in this phase.
- Redis is not required yet.
- AI layers are not public to viewers unless future admin review/publish workflow is implemented.

## Recommended Phase F

Phase F should be a controlled regional AI execution phase, not a national production run.

Recommended scope:

- Project: `91fbb1ae-3fea-49f7-a057-ada303260534`
- Project name: South Lebanon Fruit Trees Training Dataset
- Label field: `L4_descr`
- Start with `local_ground_truth_export` from the worker.
- Only after explicit approval, run regional feature extraction and training.
- Do not run national classification.
- Do not publish AI layers to viewers.
- Do not insert predictions into `spatial_feature`.

Phase F should prove a controlled worker-driven regional workflow before any larger or public AI result is considered.

## Merge Recommendation

Phase E is the tip branch containing Phases A through D.

Do not merge to `handover-ready` until:

- Phase E CI is green.
- The branch stack has been reviewed.
- The user explicitly approves the merge.

If one combined AI integration branch is needed later, use:

`feature/ai-integration-pipeline-bridge-phase-e`

That branch already carries the sequential Phase A to E work.

## Checkpoint Conclusion

The app now has a safe AI integration foundation:

- Database schema is prepared.
- Backend readiness and run-management endpoints exist.
- Super-admin UI can inspect and configure AI readiness/runs.
- Worker skeleton can process safe status transitions.
- Worker can bridge to the external AI pipeline for dry-run and local-only readiness tasks.

The system is ready for a carefully controlled Phase F, but it is not yet a production AI execution system and does not yet publish AI results to users.
