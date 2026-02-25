# Phase 10: Release Gates

## API Gate (local)
Run from `apps/api`:

```bash
npm run release:gate
```

This executes:
1. `lint`
2. `typecheck`
3. CI-safe tests (unit + integration + e2e)
4. performance tests (bbox + exports)
5. production dependency audit
6. Jest global coverage thresholds (enforced via config)

## Performance Threshold Environment Variables
- `PERF_BBOX_FEATURE_COUNT` (default: `2500`)
- `PERF_BBOX_MAX_MS` (default: `2000`)
- `PERF_EXPORT_FEATURE_COUNT` (default: `1200`)
- `PERF_EXPORT_MAX_MS` (default: `30000`)
- `PERF_EXPORT_TIMEOUT_MS` (default: `60000`)

Use tighter thresholds in staging/production-like environments if needed.

## CI Pipelines Updated
- `.github/workflows/ci.yml`
- `.github/workflows/monorepo-ci.yml`

API CI now includes:
1. PostGIS service container
2. DB readiness check
3. migration run
4. lint/typecheck/test/perf/audit

Mobile CI includes:
1. `flutter analyze`
2. `flutter test --coverage`
3. `dart run tool/check_coverage.dart --min-line 19`

## Suggested Release Policy
1. Block merge when any gate fails.
2. Keep performance tests mandatory for backend changes touching sync/bbox/exports.
3. Run full release gate before production deployment.
