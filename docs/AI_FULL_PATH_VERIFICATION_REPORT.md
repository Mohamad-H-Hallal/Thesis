# AI Full Path Verification Report

Date: 2026-06-11

## Scope

This report verifies the integrated regional AI path across the app repo and the external AI pipeline repo.

Project:
- South Lebanon Fruit Trees Training Dataset
- Project ID: `91fbb1ae-3fea-49f7-a057-ada303260534`
- Label field: `L4_descr`

Verified scope:
- Regional/project area only.
- National Lebanon remains locked.
- AI outputs remain separate from `spatial_feature`.
- No AI layer is published automatically.

## Summary

The app-integrated regional AI path is real for the regional proof-of-concept workflow. The backend creates a run configuration JSON from saved AI settings, passes it to the Python pipeline with a safe argument array, and the Python pipeline consumes the selected settings for regional feature extraction, model evaluation, and review artifact generation.

The verified Phase R path was intentionally split into two worker runs:

1. A `regional_model_eval` run for ground-truth export, Sentinel-2 feature extraction, and model evaluation.
2. A `regional_vectorization_artifacts` run for regional review predictions and classification/confidence/uncertainty review artifacts.

The current app action now queues a single `regional_full_review_artifacts` run that executes those regional steps in one worker pass when `npm run ai:worker:bridge-once` is running.

This is real regional processing, but it is not wall-to-wall national Lebanon classification and it is not official field data.

## Integrated Runs

### Model Evaluation Run

- App run ID: `eba34883-7b89-44b3-a839-2198faab368c`
- Pipeline run ID: `app-ai-eba348837b8944b3a8392198`
- Execution mode: `regional_model_eval`
- Final status: `ready_for_review`
- Worker status sequence: `extracting_features`, `training`, `evaluating`, `ready_for_review`
- Logs written: 19
- Runtime: about 132.5 seconds

### Review Artifact Run

- App run ID: `ab28c63f-b2cf-4fd7-b046-393606948357`
- Pipeline run ID: `app-ai-ab28c63fb2cf4fd7b0463936`
- Execution mode: `regional_vectorization_artifacts`
- Final status: `ready_for_review`
- Worker status sequence: `extracting_features`, `classifying`, `ready_for_review`
- Logs written: 16
- Runtime: about 11.6 seconds

## Settings Used

The verified run configuration used:

- Satellite source: Sentinel-2
- Season: Summer
- Date range: `2025-06-01` to `2025-08-31`
- Label field: `L4_descr`
- Training samples area: `project_area`
- Prediction area: `project_area`
- Selected extracted features:
  - `B2`
  - `B3`
  - `B4`
  - `B5`
  - `B8`
  - `B11`
  - `B12`
  - `NDVI`
  - `EVI`
  - `NDRE`
- Preferred model: `random_forest`
- `national_scope_enabled`: `false`
- `allow_spatial_feature_writes`: `false`
- `publish_outputs`: `false`

The run config contains no secrets.

## Step Truth Table

| Step | App-integrated use | Real or preparation | Command path | Inputs | Outputs | DB writes | GEE | Trains | Classifies | Artifact registration | Honest UI/status wording |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `01_export_ground_truth.py` | Used by `regional_model_eval` worker | Real local export of approved app data | `01_export_ground_truth.py --project-id ... --label-field L4_descr --local-only` | Approved project samples and label field | `outputs/projects/.../ground_truth.geojson` | Does not write AI predictions; reads app data | No | No | No | No direct layer registration | "Prepared approved project data for AI training." |
| `02_extract_features_gee.py` / regional feature extraction | Used by `regional_model_eval` worker through `run_pipeline.py` | Real Sentinel-2 feature extraction | `run_pipeline.py --regional-feature-extraction --project-id ... --label-field L4_descr --config <run_config.json>` | Ground truth, Sentinel-2, date range, selected features, project area | `feature_table.csv`, `feature_extraction_summary.json` | No `spatial_feature` writes | Yes | No | No | No direct layer registration | "Extracted satellite features for approved project samples." |
| `03_train_models.py` / regional model eval | Used by `regional_model_eval` worker through `run_pipeline.py` | Real training/evaluation | `run_pipeline.py --regional-model-eval --project-id ... --label-field L4_descr --config <run_config.json>` | `feature_table.csv`, selected features, preferred model | `metrics.json`, `model_metadata.json`, `confusion_matrix.csv`, `classification_report.csv`, `feature_importance.csv` | Inserts AI metrics/class statistics/output statistics layer | No | Yes | No map classification | Registers metric rows, class stats, and a statistics output layer | "Evaluated regional AI models using approved project data." |
| `04_classify_lebanon.py` / regional classification mode | Used by `regional_vectorization_artifacts` worker through `run_pipeline.py` | Real regional review predictions over extracted sample features; not wall-to-wall pixel classification | `run_pipeline.py --regional-classification --project-id ... --label-field L4_descr --config <run_config.json>` | Source model metadata, feature table, project-area settings | `regional_classification_summary.json`, `classification_polygons.geojson`, `confidence_polygons.geojson`, `uncertainty_areas.geojson` | No `spatial_feature` writes | No new GEE call in this run | No new training | Yes, over extracted sample features; not satellite image pixels | Registration happens after vector artifact step | "Generated regional AI review predictions from extracted sample features." |
| `05_vectorize_and_insert.py` / review artifact mode | Used by `regional_vectorization_artifacts` worker through `run_pipeline.py` | Real review artifact preparation; insert mode is disabled | `run_pipeline.py --regional-vectorization-artifacts --project-id ... --label-field L4_descr --config <run_config.json>` | Regional classification output | `vectorization_summary.json` and registered review artifacts | Writes only AI tables; no `spatial_feature` insert | No | No | No extra classification | Registers classification, confidence, uncertainty, and statistics output layers | "Prepared regional classification, confidence, and uncertainty review artifacts." |

## Outputs Generated

All generated files are under ignored AI repo `outputs/` paths and must not be committed.

Model evaluation outputs:

- `outputs/projects/91fbb1ae-3fea-49f7-a057-ada303260534/ground_truth.geojson`
- `outputs/runs/app-ai-eba348837b8944b3a8392198/feature_table.csv`
- `outputs/runs/app-ai-eba348837b8944b3a8392198/feature_extraction_summary.json`
- `outputs/runs/app-ai-eba348837b8944b3a8392198/metrics.json`
- `outputs/runs/app-ai-eba348837b8944b3a8392198/model_metadata.json`
- `outputs/runs/app-ai-eba348837b8944b3a8392198/confusion_matrix.csv`
- `outputs/runs/app-ai-eba348837b8944b3a8392198/classification_report.csv`
- `outputs/runs/app-ai-eba348837b8944b3a8392198/feature_importance.csv`

Review artifact outputs:

- `outputs/runs/app-ai-ab28c63fb2cf4fd7b0463936/regional_classification_summary.json`
- `outputs/runs/app-ai-ab28c63fb2cf4fd7b0463936/classification_polygons.geojson`
- `outputs/runs/app-ai-ab28c63fb2cf4fd7b0463936/confidence_polygons.geojson`
- `outputs/runs/app-ai-ab28c63fb2cf4fd7b0463936/uncertainty_areas.geojson`
- `outputs/runs/app-ai-ab28c63fb2cf4fd7b0463936/vectorization_summary.json`

Feature counts:

- Feature table rows: 1394
- Classification review features: 1394
- Confidence review features: 1394
- Uncertainty review features: 279

## Model Metrics

The model evaluation run trained/evaluated the regional models using the selected feature set.

| Model | Overall accuracy | Macro F1 | Weighted F1 |
| --- | ---: | ---: | ---: |
| Random Forest | 0.7785 | 0.5461 | 0.7449 |
| SVM RBF | 0.7163 | 0.6168 | 0.7391 |
| XGBoost | 0.7924 | 0.5765 | 0.7600 |

The requested preferred model was `random_forest`, so the classification artifact run used Random Forest. The metrics still show that SVM RBF had the best macro-F1 and XGBoost had the highest accuracy.

## Class Statistics

Reference/sample counts:

- Citrus fruit trees: 201
- Fruit trees: 253
- Olives: 940
- Vineyards: 12, excluded due to low sample count

Review prediction counts:

- Citrus fruit trees: 181
- Fruit trees: 66
- Olives: 1147

## Database Registration

The integrated run wrote to AI tables only.

Registered model-eval artifacts:

- `ai_run_metric`: model metric rows for Random Forest, SVM RBF, and XGBoost
- `ai_class_statistic`: class count rows
- `ai_output_layer`: statistics layer with status `ready_for_review`

Registered review artifact layers:

- Classification layer: `ready_for_review`, `published_at = null`
- Confidence layer: `ready_for_review`, `published_at = null`
- Uncertainty layer: `ready_for_review`, `published_at = null`
- Statistics layer: `ready_for_review`, `published_at = null`

## Safety Checks

Before and after the integrated verification:

- `spatial_feature` count stayed `1707`.
- Published AI output layer count stayed `3`.
- No AI prediction was inserted into `spatial_feature`.
- No layer was published automatically.
- National Lebanon stayed disabled in run config and pipeline metadata.
- AI outputs stayed under ignored `outputs/`.
- Run config files stayed under ignored app temp paths.
- Logs were checked for operational summaries, not secrets.

## UI and Wording Audit

Corrected wording:

- The AI run helper says the app queues a regional review run and results appear after the backend AI worker processes it.
- The backend no longer describes queued runs as placeholders. It says queued runs are waiting for worker processing.
- Regional artifact modes now have explicit labels:
  - Regional review prediction
  - Regional review artifacts
  - Full regional review run

Still intentionally honest:

- `Start AI run` queues a regional worker run. It does not claim completion; if the worker is not running, the UI shows the run as queued.
- National Lebanon remains locked/future until backend readiness requirements are met.
- AI predictions are shown as review/published AI overlays, not approved field data.
- Statistics are report summaries, not editable official field features.

## What Is Real Now

- App-approved project data can feed the AI pipeline.
- Backend creates and stores a run config JSON from saved AI settings.
- Python consumes the run config for regional/project-area runs.
- Sentinel-2 regional feature extraction runs through GEE.
- Regional model evaluation trains/evaluates supported models.
- Regional review prediction artifacts can be generated.
- Artifacts can be registered as AI output layers.
- Super-admin review and publishing workflows can control viewer visibility.
- Viewer AI overlays remain read-only and separate from field data.

## What Remains Future

- National Lebanon classification.
- National scope unlock and national validation workflow.
- Production queue scaling with Redis or another durable queue.
- Automatic retraining.
- Contributor uncertainty validation workflow.
- True wall-to-wall pixel classification for the regional artifact path, if required by the scientific workflow.
- Production hardening around long-running GEE jobs and retry policies.

## Thesis Demo Readiness

The current AI path is thesis-demo ready for a regional/project proof-of-concept if the demo clearly states:

- It is regional, not national.
- It uses project-approved samples.
- It generates reviewable AI predictions/artifacts.
- AI predictions are not official field data.
- Viewer visibility requires explicit publishing.
- National Lebanon remains locked until data, validation, and pipeline requirements are met.

## Merge Recommendation

The app Phase Q branch can be considered the current complete AI integration branch after final validation. The AI repo Phase Q branch is the matching pipeline branch.

Recommended next merge path after approval:

1. Merge app `feature/ai-settings-driven-pipeline-phase-q` into the approved integration/handover branch.
2. Keep AI repo `feature/ai-settings-config-phase-q` paired with the app branch, or merge it to the AI repo main branch after approval.
3. Do not enable National Lebanon or production scheduling during merge.
