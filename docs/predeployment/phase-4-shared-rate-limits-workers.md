# Phase 4 — Shared Rate Limits and Durable Workers

Status: repository gate complete. PR
[#11](https://github.com/Mohamad-H-Hallal/Thesis/pull/11) merged into protected
`handover-ready` as `17af7d7634a026aa36575d6c8b66a451d3df85ee`
after all required GitHub checks passed.

This phase protects expensive endpoints across API replicas and moves
production import/export processing to a durable, separately scalable worker.
It makes no production or staging changes.

## Completed controls

- Added Redis/Valkey-backed stores for anonymous, authentication, password
  reset, imports, exports, AI jobs, map aggregation, notifications, offline
  synchronization, bundles, photos, and pre-authentication offline ingress.
- Preserved retryable 429 responses and `Retry-After` for mobile sync.
- Added fail-closed 503 behavior and independent readiness reporting for
  shared-counter outages.
- Production configuration refuses memory-only rate limiting.
- Added migration `0044_durable_workload_queue.sql`.
- Import/export requests enqueue their domain row and workload row
  transactionally.
- Added multi-worker claiming, leases, heartbeats, bounded concurrency,
  retries/backoff, timeouts, dead-letter state, terminal-result detection, and
  restart recovery.
- Production configuration refuses inline workers; Compose defines separate
  API and workload-worker services.
- Pinned Valkey 8.1.9 by its multi-architecture image digest.
- Preserved existing upload, archive, feature-count, pagination, map-tile, and
  AI execution bounds.

The detailed policy, failure behavior, operations, and rollback design is in
[`shared-rate-limits-and-workload-workers.md`](../security/shared-rate-limits-and-workload-workers.md).

## Local evidence

Recorded on 2026-07-29:

- migration 0044 applied cleanly to the test database;
- a separate empty verification database applied all 45 migration files and
  recorded all 45 checksums; the temporary database was then dropped;
- TypeScript typecheck and ESLint passed;
- 49 existing import, export, and map regression tests passed;
- three queue tests proved cross-worker exclusive claims, expired-lease
  recovery, bounded retries, and dead-letter disposition;
- two tests against a real pinned Valkey container proved shared enforcement
  across two Express replicas and fail-closed outage behavior;
- the workload load suite processed six concurrent 25-feature GIS files from
  three users in 3.652 seconds, producing exactly 150 unique staged rows and
  six succeeded jobs;
- a simulated worker crash recovered the expired lease on attempt two and
  produced exactly 40 unique staged rows;
- all canonical development and production Compose files rendered
  successfully with an injected test-only Valkey password;
- the isolated Valkey verification container was stopped and removed after
  testing.
- a clean `npm ci` installed 667 audited packages and both the production-only
  and complete audits reported zero vulnerabilities;
- the complete API release gate passed in 10 minutes 57 seconds, including
  OpenAPI validation, ESLint, typecheck, the full instrumented API suite,
  70.99% line coverage, all four performance scenarios, and the final
  production audit.
- Flutter 3.41.2/Dart 3.11.0 resolved the locked dependencies from the offline
  cache, analysis reported no issues, and all 343 tests passed with 51.09%
  line coverage (14,612 of 28,601 lines).

GitHub required checks, PR, and protected merge are recorded after they run.

## Remaining external gates

These are deliberately deferred to staging/release infrastructure:

- managed Redis/Valkey TLS, authentication, failover, latency, and alarms;
- two deployed API replicas sharing counters through that managed service;
- independently deployed workload-worker replicas with shared object storage;
- forced worker termination during realistic large imports and exports;
- dead-letter alert delivery and operator-reviewed requeue;
- sustained load/cost testing at the intended production instance sizes.

Phase 4 is not a deployment approval. Phase 5 consumes these artifacts to
build the real staging environment and release pipeline.
