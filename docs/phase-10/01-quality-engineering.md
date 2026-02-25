# Phase 10: Quality Engineering

## Goal
Provide repeatable quality gates for backend and mobile before release.

## Scope Implemented
- API unit/integration/e2e coverage:
  - smoke tests
  - geospatial integration tests
  - full end-to-end workflow test
- API performance baselines:
  - BBOX query latency + geospatial index usage
  - export generation latency + downloadable artifact check
- Mobile quality checks:
  - static analysis
  - sync queue integration tests
  - sync performance baseline test
- CI release gates for pull requests and pushes.

## API Test Matrix
- `test/app.test.js`: smoke/unit API checks.
- `test/phase3.integration.test.js`: geometry validation, bbox response and explain/index checks.
- `test/phase10.e2e.workflow.test.js`: auth -> project -> assignment -> submit/review -> export/download flow.
- `test/phase10.performance.bbox.test.js`: BBOX SLA + index plan assertion.
- `test/phase10.performance.exports.test.js`: async export SLA + file artifact assertion.

## Mobile Test Matrix
- `test/core/sync/sync_engine_integration_test.dart`: queue transition flows and conflict/retry behavior.
- `test/core/sync/sync_engine_performance_test.dart`: small sync batch throughput baseline.
- existing feature tests under `test/features/**`.

## Quality Commands
API (`apps/api`):
```bash
npm run lint
npm run typecheck
npm run test:ci
npm run test:perf
npm run release:gate
```

Mobile (`apps/mobile`):
```bash
flutter analyze
flutter test
```

## Exit Criteria
- Lint/typecheck clean.
- API unit/integration/e2e tests passing.
- API performance tests under configured thresholds.
- Mobile analyze/tests passing.
- CI gates green.
- Coverage thresholds enforced:
  - API (Jest global): lines `>=30%`, statements `>=30%`, functions `>=20%`, branches `>=15%`.
  - Mobile (LCOV line coverage): `>=19%`.
