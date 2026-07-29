# Shared Rate Limits and Durable Workload Workers

This design bounds expensive API work across replicas and removes GIS import
and export execution from production API processes. It does not authorize a
production deployment or provision a managed Redis/Valkey service.

## Security invariants

- Production refuses to start unless `RATE_LIMIT_STORE=redis`.
- Every rate-limit policy has a distinct key prefix; authenticated expensive
  work is keyed by user and policy, not only by source IP.
- Redis/Valkey errors fail closed. Requests do not bypass limits while the
  shared counter service is unavailable.
- `/ready` reports database and shared-counter health independently and returns
  503 if either required production dependency is down.
- The mobile offline-sync 429 response remains retryable and includes
  `Retry-After`.
- Imports and exports are inserted with their durable queue row in the same
  database transaction.
- Workers claim jobs with `FOR UPDATE SKIP LOCKED`; two replicas cannot own the
  same unexpired lease.
- Leases are renewed while work runs and may be recovered only after expiry.
- Retry count, exponential backoff, execution timeout, and dead-letter
  disposition are bounded.
- Production runs workers as a separate process and enables hard process exit
  on execution timeout. API processes never execute queued work in that mode.
- Import processing is idempotent: staged rows are replaced within one
  transaction. Export processing verifies the published package before
  committing its reference.
- A worker that completed domain work but crashed before acknowledging its
  queue row is safe: the next worker detects the terminal domain state and
  acknowledges the existing result without duplicating it.

## Rate-limit policy matrix

| Policy | Identity | Default window/max | Covered work |
| --- | --- | --- | --- |
| anonymous API | normalized client IP | 15 minutes / 100 | unauthenticated API ingress |
| authentication | normalized client IP | 15 minutes / 20 | login, registration, token operations |
| password reset | normalized client IP | 1 minute / 5 | request, verify, reset |
| import upload | authenticated user | 1 minute / 6 | upload, inspection, malware scan, queue |
| export create | authenticated user | 1 minute / 10 | export validation and queue |
| AI jobs | authenticated user | 1 minute / 10 | create, publish, cancel, resume, review, retrain |
| map aggregation | authenticated user | 1 minute / 60 | bbox, tile, import map, stats, offline package |
| notifications | authenticated user | 1 minute / 30 | read-state and device mutations |
| offline sync/bundle/photo | authenticated user | 1 minute / 60 | synchronization and attachment writes |
| offline ingress | normalized client IP | 1 minute / 240 | body/authentication work before offline routes |

All values are environment-configurable positive integers. Pagination and map
result ceilings remain enforced by request validators and controller caps.
Photo decoding remains sequentially bounded, upload/archive limits are
enforced before parsing, and AI HTTP/subprocess calls retain their configured
timeouts.

## Redis/Valkey behavior

Development and tests may use the process-local memory store. That fallback is
explicitly non-production and does not coordinate replicas.

Production uses an authenticated managed Redis/Valkey endpoint or the
password-protected Compose service. Use TLS (`rediss://`) whenever traffic
leaves a private local container network. Credentials must come from the
deployment secret manager and must not be committed.

On startup the API connects and pings the counter service before listening.
Reconnect attempts use bounded exponential delay. At runtime, a disconnected
store causes a retryable 503
`RATE_LIMIT_BACKEND_UNAVAILABLE`; readiness also becomes unhealthy. This
fail-closed policy protects expensive operations during a counter outage.

## Durable queue states

`queued` jobs are eligible at `available_at`. A worker atomically changes a
bounded batch to `running`, increments `attempt_count`, records `worker_id`,
and sets `lease_expires_at`. A heartbeat extends the lease.

Successful work becomes `succeeded`. Failed work becomes `queued` with bounded
exponential delay until `max_attempts`; the last failure becomes
`dead_letter`, updates the domain job to failed, and preserves the bounded
error text for support. Dead-letter rows are never automatically discarded.

The queue does not use Redis as its source of truth. PostgreSQL provides
transactional enqueueing with the existing import/export rows and preserves
work across Redis outages.

## Operations and recovery

Production requires:

- one or more API replicas with `WORKLOAD_WORKER_MODE=external`;
- one or more `node dist/jobs/runWorkloadWorker.js` processes sharing the
  database and storage;
- identical mounted/object-storage namespaces for every worker;
- `WORKLOAD_HARD_EXIT_ON_TIMEOUT=true` so an over-time job process exits and
  its lease can be recovered;
- alerts for Redis readiness failures, queued-job age, expired leases,
  dead-letter count, and worker restarts.

Safe recovery sequence:

1. Stop only the affected worker process; do not edit domain or queue rows.
2. Confirm its lease and domain status.
3. Restore database/storage/Redis availability.
4. Start a worker and wait for lease expiry or explicitly review the row before
   changing `lease_expires_at`.
5. Verify the domain result, `workload_job.status`, row/file counts, and
   checksums.
6. Requeue a dead-letter item only after the root cause and output cleanup have
   been reviewed.

Never delete queue rows to make a dashboard green. They are operational audit
evidence.

## External staging gates

Repository tests prove counter sharing with a real local Valkey process and
worker recovery with Postgres. Before deployment, staging must still prove:

- managed Redis/Valkey authentication, TLS, failover, latency, and outage
  alarms from two actual API replicas;
- independent worker scaling, forced process termination mid-import/export,
  lease recovery, and no duplicate/corrupt database or object-storage output;
- realistic large GIS files and concurrent users at the intended instance,
  database, storage, and cost limits;
- dead-letter alerting and an operator-reviewed requeue exercise.
