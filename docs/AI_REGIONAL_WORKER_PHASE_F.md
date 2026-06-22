# AI Regional Worker Phase F

Phase F extends the AI worker bridge from safe dry-run commands to controlled regional execution modes. It still does not classify all Lebanon, publish layers, insert AI predictions into `spatial_feature`, or add Redis.

## Allowed Execution Modes

The worker can process queued `ai_run` records with:

- `local_ground_truth_export`
- `regional_feature_extraction`
- `regional_model_eval`

The existing `mock` and `dry_run` modes remain available for development and safety checks.

## Blocked Work

Phase F still blocks:

- National classification
- Vectorization or insertion into the app database
- Publishing AI layers
- Redis/queue scaling
- Arbitrary shell commands
- Direct writes to approved field/import data

AI outputs remain metadata/output paths on `ai_run` and logs in `ai_run_log`.

## Safety Checks

Before regional extraction or model evaluation, the worker checks:

- The AI pipeline bridge is enabled.
- The project exists.
- The selected label field has approved labels.
- Approved features exist.
- At least two classes meet the configured sample threshold.
- The run does not request national scope.
- The execution mode is in the Phase F allowlist.

If any check fails, the run is marked `failed` with a clear reason and sanitized logs.

## Status Mapping

`regional_feature_extraction`:

```text
queued -> extracting_features -> ready_for_review
```

`regional_model_eval`:

```text
queued -> extracting_features -> training -> evaluating -> ready_for_review
```

No Phase F run is marked `published`.

## Commands

The bridge calls the external AI repo with argument arrays:

```text
config.py --check
run_pipeline.py --dry-run
run_pipeline.py --probe-db --project-id <project_id> --label-field <label_field>
01_export_ground_truth.py --project-id <project_id> --label-field <label_field> --local-only
run_pipeline.py --regional-feature-extraction --project-id <project_id> --label-field <label_field> --ground-truth outputs/projects/<project_id>/ground_truth.geojson --regional-run-id <run_id>
run_pipeline.py --regional-model-eval --project-id <project_id> --label-field <label_field> --feature-table outputs/runs/<run_id>/feature_table.csv --regional-run-id <run_id>
```

Logs are sanitized before storage. Secrets, `.env` contents, GEE keys, and private key values are not returned through the API.

## Local Smoke

For a local app worker bridge smoke, configure ignored environment values only:

```text
AI_PIPELINE_ENABLED=true
AI_PIPELINE_ROOT=<external AI repo path>
AI_PYTHON_BIN=<external AI repo Python 3.11 venv python>
AI_PIPELINE_MODE=local_ground_truth_export
AI_PIPELINE_TIMEOUT_MS=120000
```

Then queue a safe project-scoped run and execute:

```bash
npm run ai:worker:bridge-once
```

Run regional feature extraction or regional model evaluation only after explicit approval, because those modes can call GEE or train regional proof-of-concept models.

## Scientific Boundary

Phase F supports a regional proof-of-concept only. It is not a national production model and should not be presented as national accuracy. AI output paths are review artifacts until a later admin review/publish workflow is implemented.
