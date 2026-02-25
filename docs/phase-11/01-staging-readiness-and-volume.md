# Phase 11: Staging Readiness and Realistic Volume

## Goal
Run a production-like staging environment with realistic data volume before pilot and go-live.

## Pre-conditions
- Phase 10 release gate is passing.
- PostGIS staging database is provisioned.
- Secrets are injected from secure storage (not from git).
- Backup and restore drill from phase 9 has been executed successfully.

## Staging Data Seeding
From `apps/api`:

```bash
npm run migrate
npm run seed:staging
npm run staging:verify
```

## Seed Configuration (Environment Variables)
- `STAGING_SEED_RESET` (default: `true`)
- `STAGING_SEED_ADMINS` (default: `6`)
- `STAGING_SEED_CONTRIBUTORS` (default: `55`)
- `STAGING_SEED_VIEWERS` (default: `15`)
- `STAGING_SEED_PROJECTS` (default: `18`)
- `STAGING_SEED_CONTRIBUTORS_PER_PROJECT` (default: `8`)
- `STAGING_SEED_FEATURES_PER_PROJECT` (default: `350`)
- `STAGING_SEED_PHOTO_RATIO` (default: `0.35`)
- `STAGING_SEED_EXPORTS_PER_PROJECT` (default: `2`)
- `STAGING_SEED_DEFAULT_PASSWORD` (default: `Phase11@Seed123`)

## Verification Thresholds
- `STAGING_VERIFY_STRICT` (default: `true`)
- `STAGING_VERIFY_MIN_USERS` (default: `40`)
- `STAGING_VERIFY_MIN_PROJECTS` (default: `10`)
- `STAGING_VERIFY_MIN_ASSIGNMENTS` (default: `60`)
- `STAGING_VERIFY_MIN_FEATURES` (default: `1500`)
- `STAGING_VERIFY_MIN_PHOTOS` (default: `300`)
- `STAGING_VERIFY_MIN_COMPLETED_EXPORTS` (default: `5`)
- `STAGING_VERIFY_MAX_BBOX_MS` (default: `400`)

## Exit Criteria
- No pending migrations.
- Dataset volumes meet thresholds.
- Spatial index is used for BBOX query plan.
- BBOX latency meets baseline threshold.
- API `/health` and `/ready` are green.
