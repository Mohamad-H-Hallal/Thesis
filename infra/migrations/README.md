# SQL Migrations (Source of Truth)

This is the only migration tree used by the API migration runner (`apps/api/src/db/migrationRunner.ts`).

Conventions:
- Ordered numeric filenames (`0001_*.sql`, `0002_*.sql`, ...).
- Migrations are tracked in `schema_migrations`.
- The runner verifies every applied file still exists and matches its recorded
  SHA-256 checksum before reporting pending migrations or applying new ones.
- Checksums canonicalize line endings to LF and recognize the exact working-copy
  hash plus legacy LF/CRLF hashes, so moving between Linux and Windows does not
  create false drift.
- `checksum-compatibility.json` is reserved for proven pre-release database
  hashes. Every exception is pinned to the current canonical source checksum,
  requires a reason, and becomes invalid if that source changes.
- Never edit, rename, or delete an applied migration. Add a new migration that
  moves the schema or data forward.
- Each file must be idempotent where practical (`IF NOT EXISTS` / guarded DDL).
- Data migrations must be restart-safe or use a durable progress marker, emit
  before/after counts, and verify the transformed records before old data is
  removed.

Do not place credentials or environment-specific data in migration files.
