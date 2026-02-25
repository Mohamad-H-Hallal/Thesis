# SQL Migrations (Source of Truth)

This is the only migration tree used by the API migration runner (`apps/api/src/db/migrationRunner.ts`).

Conventions:
- Ordered numeric filenames (`0001_*.sql`, `0002_*.sql`, ...).
- Migrations are tracked in `schema_migrations`.
- Each file must be idempotent where practical (`IF NOT EXISTS` / guarded DDL).

Do not place credentials or environment-specific data in migration files.
