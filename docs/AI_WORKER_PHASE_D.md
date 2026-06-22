# AI Worker Phase D

Phase D adds a backend worker skeleton for AI run status transitions only. It does not execute the Python AI pipeline, Google Earth Engine jobs, model training, classification, layer publishing, or database insertion of AI outputs.

## Command

From `apps/api`:

```bash
npm run ai:worker:once
npm run ai:worker:dry-run
```

`ai:worker:once` processes one queued `ai_run` in mock mode. `ai:worker:dry-run` reports the next queued run without mutating it.

## Status Flow

Mock execution advances one queued run through:

```text
queued -> extracting_features -> training -> evaluating -> ready_for_review
```

Each step writes an `ai_run_log` entry with `real_ai_execution: false`. A mock failure can mark an active run as `failed` with a `failure_reason`.

## Concurrency

The worker claims one queued run inside a database transaction using `FOR UPDATE SKIP LOCKED`. That prevents two worker processes from claiming the same `ai_run`.

## Safety Boundaries

- No Python process is spawned.
- No GEE APIs are called.
- No model training or classification runs.
- No records are inserted into `spatial_feature`.
- No AI output layers, metrics, class statistics, or uncertainty areas are created.
- Redis and async queue infrastructure remain future work.

Future phases can replace the mock step handlers with real, reviewed processing while keeping the same run/log tables and status lifecycle.
