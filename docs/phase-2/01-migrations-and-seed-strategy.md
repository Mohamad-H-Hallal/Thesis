# Phase 2 - Migration and Seed Strategy

## Migration Strategy

1. Migration files live only in `infra/migrations` and are ordered with numeric prefixes.
2. API command `npm run migrate` runs unapplied SQL files in lexical order.
3. Applied files are tracked in table `schema_migrations`.
4. Each migration runs in its own transaction; failed migration is rolled back.

## Seed Strategy

1. Development seed SQL lives in `infra/db/seeds`.
2. API command `npm run seed` applies `001_seed_dev.sql`.
3. Seed file uses `ON CONFLICT DO NOTHING` for idempotent re-runs.
4. No production secrets are seeded.

## Current Files

- `infra/migrations/0001_extensions.sql`
- `infra/migrations/0002_core_schema.sql`
- `infra/migrations/0003_indexes.sql`
- `infra/migrations/0004_phase3_geospatial_constraints.sql`
- `infra/migrations/0005_phase11_hardening_constraints.sql`
- `infra/migrations/0006_validate_hardening_constraints.sql`
- `infra/db/seeds/001_seed_dev.sql`

## Operational Notes

1. Run `npm run migrate` before API startup in all environments.
2. Run `npm run seed` only in local/dev test environments.
3. Keep backward compatibility for API changes until Phase 6 freeze.
4. `apps/api/src/db/migrations` is retired to prevent migration drift.

## Phase 11 Hardening Additions

`0005_phase11_hardening_constraints.sql` adds production hardening without renaming schema fields:

1. Constraint guards:
`project.category_id` required for new/updated rows.
`project_assignment` approved status requires `approved_by_user_id` + `approved_date`.
`spatial_feature` approved/rejected requires `reviewed_by_user_id` + `reviewed_at`.
`shapefile_export` failed requires `error_message`; completed requires `file_path`.
`notification.metadata` must be a JSON object.
2. Triggers:
project status transition guard (`draft -> active -> completed -> archived`),
`project.updated_at` auto-refresh,
notification metadata context-id validation,
photo min/max enforcement against project policy.
3. Uniqueness guard:
partial unique index on `lebanon_offline_map(is_current)` to allow only one current offline map version.
4. Global enforcement:
`0006_validate_hardening_constraints.sql` validates the hardening constraints against existing rows so enforcement applies to the full dataset, not only new writes.
