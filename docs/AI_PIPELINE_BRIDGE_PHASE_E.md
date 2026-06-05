# AI Pipeline Bridge Phase E

Phase E connects the backend AI worker to the external AI pipeline in a safe, dry-run-only way. It proves the backend can locate the AI repo, run approved readiness commands, capture sanitized logs, and update `ai_run` status without starting heavy AI processing.

## Safety Boundary

Allowed in Phase E:

- AI config check: `config.py --check`
- AI dry-run: `run_pipeline.py --dry-run`
- Project readiness probe: `run_pipeline.py --probe-db --project-id <id> --label-field <field>`
- Local-only ground-truth export: `01_export_ground_truth.py --project-id <id> --label-field <field> --local-only`

Blocked in Phase E:

- Full GEE feature extraction
- Model training
- Lebanon classification
- Vectorization or insertion into the app database
- AI layer publishing
- Redis or production queue integration
- Arbitrary command execution

## Configuration

The bridge is disabled by default.

```bash
AI_PIPELINE_ENABLED=false
AI_PIPELINE_ROOT=
AI_PYTHON_BIN=python
AI_PIPELINE_TIMEOUT_MS=60000
AI_PIPELINE_MODE=disabled
```

`AI_PIPELINE_ROOT` should point to the external AI repo folder. It must not contain secrets in the app repo. The backend does not print `.env` values, GEE keys, private keys, database passwords, or service account values.

`AI_PIPELINE_MODE` can be:

- `disabled`
- `dry_run`
- `local_ground_truth_export`

Run metadata can also request:

- `mock`
- `dry_run`
- `local_ground_truth_export`

If `AI_PIPELINE_ENABLED=false`, the worker remains in the mock Phase D path even if a run asks for a pipeline mode.

## Commands

From `apps/api`:

```bash
npm run ai:worker:once
npm run ai:worker:dry-run
npm run ai:worker:bridge-once
```

`ai:worker:once` is mock-only. `ai:worker:dry-run` reports the next queued run without mutating it. `ai:worker:bridge-once` allows the Phase E bridge path, but still runs only the safe command allowlist above.

## Worker Behavior

When a queued `ai_run` is processed:

1. The worker claims one run with `FOR UPDATE SKIP LOCKED`.
2. The worker reads `metadata.execution_mode` and AI pipeline config.
3. If the pipeline is disabled or the mode is `mock`, the Phase D mock transition path is used.
4. If the pipeline is enabled and mode is `dry_run`, the worker runs config check, dry-run, and project probe.
5. If mode is `local_ground_truth_export`, the worker also runs local-only ground-truth export.
6. Command summaries, durations, and output paths are stored in `ai_run.metadata`.
7. Sanitized command logs are written to `ai_run_log`.
8. The run becomes `ready_for_review` only if all safe commands succeed.
9. Any command failure or timeout marks the run `failed` with a clear `failure_reason`.

## Failure Modes

Expected safe failures include:

- Pipeline disabled
- Missing `AI_PIPELINE_ROOT`
- Missing required AI script
- Command non-zero exit code
- Timeout
- Invalid project id or label field

These failures do not crash the API process, do not write `spatial_feature`, and do not expose secret values in logs.

## Phase F Hand-Off

Phase F extends this bridge with controlled regional feature extraction and regional model-evaluation modes. Those modes remain project-scoped, keep AI outputs separate from approved human/imported field data, and still block national classification, vectorization into the app database, publishing, and Redis scaling.
