# AI Integration Phase A to I Checkpoint

## Purpose

This checkpoint summarizes the AI app integration work completed from Phase A through Phase I. It is a report-only checkpoint before the next AI phase. It does not add app code, run GEE, train models, classify Lebanon, add Redis, merge branches, modify runtime database state, or commit generated outputs.

## Branch Stack

The AI integration work is stacked sequentially:

1. `handover-ready`
2. `feature/ai-integration-schema-phase-a`
3. `feature/ai-integration-backend-phase-b`
4. `feature/ai-integration-mobile-phase-c`
5. `feature/ai-integration-worker-phase-d`
6. `feature/ai-integration-pipeline-bridge-phase-e`
7. `feature/ai-integration-regional-worker-phase-f`
8. `feature/ai-integration-results-ui-phase-g`
9. `feature/ai-results-ui-readable-polish`
10. `feature/ai-output-artifact-registration-phase-h`
11. `feature/ai-result-review-phase-i`

`feature/ai-result-review-phase-i` is now the tip branch. It contains the work from Phases A through I.

## What Is Implemented Now

### Phase A: Schema and Provenance

Phase A added the database foundation for AI integration:

- AI storage tables for project settings, runs, metrics, output layers, class statistics, uncertainty areas, run logs, and review decisions.
- `spatial_feature.source` provenance so human-collected and imported approved field data can be distinguished by source.
- Dedicated AI output tables so AI predictions stay separate from approved field data.
- Foreign keys, status constraints, audit fields, and indexes needed for future AI workflows.

### Phase B: Backend AI Endpoints

Phase B added backend API foundations without running AI:

- AI readiness endpoint for approved project data.
- AI settings endpoints.
- AI run create, list, and detail endpoints.
- AI metrics, layers, and logs read endpoints.
- RBAC so AI management is limited to protected super-admin access.
- OpenAPI coverage for the AI endpoints.

### Phase C: Super-Admin AI Workspace

Phase C added the mobile/web AI workspace:

- Super-admin-only Project AI workspace.
- Readiness UI.
- Settings UI.
- Runs UI.
- Clean classifier field selection based on project schema and useful label candidates.
- No claim that real AI is running when only metadata, mock, or dry-run execution exists.

### Phase D: Worker Skeleton

Phase D added a safe backend worker skeleton:

- Queued-run claiming.
- Controlled status transitions.
- `ai_run_log` progress entries.
- Concurrency safety.
- Mock execution only.
- No Python execution, GEE processing, training, classification, map publishing, or `spatial_feature` output insertion.

### Phase E: Safe Pipeline Bridge

Phase E connected the worker to the external AI repo in a limited safe mode:

- AI pipeline configuration, disabled by default.
- Safe command adapter using argument arrays.
- Config check.
- Dry-run.
- Project readiness/probe.
- Local-only ground truth export mode.
- Sanitized logs and timeout handling.
- Metadata/output path capture for safe commands.

### Phase F: Controlled Regional Worker Execution

Phase F enabled controlled regional execution modes:

- `local_ground_truth_export`
- `regional_feature_extraction`
- `regional_model_eval`

The worker records controlled status transitions, logs, metadata, output paths, and regional proof-of-concept limitations. It still does not classify all Lebanon, publish AI layers, insert predictions into `spatial_feature`, or add Redis.

### Phase G: AI Results UI

Phase G improved how super-admin users inspect AI run results:

- AI run details display in the app.
- Status, execution mode, label field, scope, dates, duration, class counts, exclusions, limitations, and next-step notes are readable.
- Worker logs display in an expandable section.
- Technical output paths and metadata remain available but are hidden by default.
- Model result summary is compact and honest.

### Phase H: Artifact Registration

Phase H registered regional AI artifacts into the app AI tables:

- Parsed available regional run artifacts.
- Stored structured model results in `ai_run_metric`.
- Stored available class counts/statistics in `ai_class_statistic`.
- Registered output layer metadata in `ai_output_layer` as unpublished/admin-review-only.
- Kept AI outputs separate from `spatial_feature`.
- Kept viewer-facing map layers disabled.

### Phase I: Review Workflow

Phase I added protected super-admin review decisions for AI results:

- Backend review endpoints.
- Review history endpoint.
- Review decisions written to `ai_review_decision`.
- AI run logs for review actions.
- Output layer status transitions for internal review:
  - approve for future publication
  - reject
  - request more data
  - keep draft
- Mobile review UI in Project AI > Runs.
- Review wording that makes clear the action prepares results for a later publishing phase and does not publish AI map layers to viewers now.

## Implemented Capabilities Summary

The current tip branch includes:

- AI storage tables.
- `spatial_feature.source` provenance.
- AI readiness/settings/runs APIs.
- Super-admin Project AI workspace.
- Controlled worker execution.
- Safe pipeline bridge to the AI repo.
- Regional feature extraction/model evaluation through the worker.
- Artifact registration into `ai_run_metric`, `ai_class_statistic`, and `ai_output_layer`.
- Readable AI results UI.
- Review decisions for AI results.
- Approve for future publication, reject, request more data, and keep draft workflows.

## What Is Proven

The completed work proves the following:

- App-approved project data can be read for AI readiness and run setup.
- Local-only ground truth export works.
- GEE authentication works in the AI pipeline.
- Tiny Sentinel-2 feature extraction works.
- Regional feature extraction works for the approved South Lebanon project.
- Regional model evaluation works as a proof-of-concept.
- Backend worker status and logs flow into `ai_run` and `ai_run_log`.
- AI run details, logs, structured metrics, and review decisions display in the app.
- Registered AI artifacts are visible through backend APIs.
- AI output files remain separate from approved app field data.
- AI predictions are not inserted into `spatial_feature`.

## What Is Still Not Implemented

The following items are intentionally not implemented yet:

- Viewer-facing AI map layers.
- Actual published AI layer display on Project Map.
- Confidence or uncertainty map visualization.
- National classification.
- Redis or queue scaling.
- Production scheduling.
- Automatic retraining.
- Viewer-facing published AI result access.
- Automatic publication of AI results.
- Insertion of AI predictions into `spatial_feature`.

## Safety Guarantees

The current branch preserves these safety boundaries:

- AI predictions are not inserted into `spatial_feature`.
- AI layers are not shown to viewers yet.
- AI review does not publish map layers yet.
- Secrets are not committed.
- `.env` values are not committed.
- GEE keys are not committed.
- Raw data is not committed.
- Generated AI outputs are not committed.
- Super-admin-only controls protect AI configuration, run inspection, artifact review, and review decisions.
- Worker execution modes are controlled and allowlisted.
- The regional proof-of-concept is not claimed as a national model.
- Redis is not required yet.

## Current Best AI Result Summary

Current proof-of-concept project:

- Project: South Lebanon Fruit Trees Training Dataset
- Label field: `L4_descr`
- Scope: regional proof-of-concept, not national
- Models evaluated:
  - Random Forest
  - SVM
  - XGBoost
- Best balanced model: SVM by macro-F1
- Highest accuracy model: XGBoost
- Vineyards excluded because only 12 samples were available, below the training threshold.
- National data is still needed before national accuracy or production national classification claims can be made.

The current result is useful for thesis demonstration and app integration proof. It is not a final national production model.

## Recommended Next Phase

Recommended Phase J:

**AI output/map layer visibility preparation**

Phase J should:

- Show approved/unpublished AI output layers to super-admin/admin users only.
- Prepare map layer display using `ai_output_layer`.
- Keep layers hidden from viewers unless a later explicit publishing phase enables viewer access.
- Keep AI outputs separate from `spatial_feature`.
- Avoid inserting AI predictions into `spatial_feature`.
- Avoid adding Redis until queue scaling is actually needed.
- Avoid national classification unless explicitly approved later.

The goal for Phase J should be visibility preparation, not public publication.

## Merge Guidance

`feature/ai-result-review-phase-i` is now the tip branch containing Phases A through I.

Do not merge this branch into `handover-ready` until:

- The user approves the merge.
- The branch has been reviewed as the combined AI integration branch.
- GitHub Actions remains green.

If creating a PR later, use:

`feature/ai-result-review-phase-i`

as the combined AI integration branch. It carries the sequential AI integration work through Phase I.

## Checkpoint Conclusion

The app now has a safe, reviewable AI integration foundation:

- Schema is ready.
- Backend endpoints exist.
- Super-admin UI can inspect readiness, settings, runs, logs, regional results, structured metrics, and artifact state.
- Worker execution is controlled.
- The external AI repo can be called safely for approved regional modes.
- Regional outputs are registered as reviewable AI artifacts.
- Super-admin users can review AI results and mark them for future publication, rejection, more data, or draft retention.

The system is ready for Phase J output/map layer visibility preparation. It is still not a national production AI system and should not make national accuracy claims until balanced samples across Lebanon are collected and validated through the app.
