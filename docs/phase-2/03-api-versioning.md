# Phase 2 - API Versioning Strategy

## Active Strategy
Path-prefix versioning.

- Current prefix: `/api/v1`
- Set by env: `API_VERSION_PREFIX=/api/v1`
- Optional legacy compatibility: `ENABLE_LEGACY_API_PREFIX=true` also exposes `/api` for transition only.

## Rules

1. All new stable endpoints must be added under `/api/v1`.
2. Breaking contract changes require a new prefix (`/api/v2`).
3. Non-breaking enhancements stay in the same version.
4. `/api` legacy compatibility can be disabled after client migration.
5. Support windows for old versions are defined at release governance phase.

## Why Path Prefix

1. Explicit for mobile/web clients.
2. Simple gateway/proxy routing.
3. Easy to run multi-version endpoints during migration.

## Current Core v0/v1 Contract Scope

1. Auth: register/login/me
2. Categories: CRUD
3. Projects: CRUD
4. Assignments: list/create/status/delete
5. Features: CRUD
