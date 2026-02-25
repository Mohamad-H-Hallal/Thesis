# infra/db/init

Use this directory only for one-time database bootstrap SQL that must run before
application migrations.

Current deployment relies on `infra/migrations` as the single schema source of truth,
so this folder is intentionally empty.
