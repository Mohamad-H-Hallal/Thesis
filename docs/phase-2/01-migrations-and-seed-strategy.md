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
- `infra/db/seeds/001_seed_dev.sql`

## Operational Notes

1. Run `npm run migrate` before API startup in all environments.
2. Run `npm run seed` only in local/dev test environments.
3. Keep backward compatibility for API changes until Phase 6 freeze.
4. `apps/api/src/db/migrations` is retired to prevent migration drift.
