# Architecture Overview

## Monorepo Layout
- `apps/api`: Node.js + TypeScript API (Express, Postgres/PostGIS)
- `apps/mobile`: Flutter app (Riverpod, GoRouter, Dio)
- `infra/db`: Docker Compose stack for Postgres/PostGIS
- `infra/migrations`: canonical SQL migrations
- `docs`: phase docs, governance docs, handover docs

## Text Architecture Diagram
```text
[Flutter Mobile/Web]
  - Riverpod state
  - GoRouter guards
  - Dio API client
  - Secure token storage
          |
          | HTTPS / JSON
          v
[API Gateway Layer - Express app]
  - /health /ready /metrics
  - /api/v1/* versioned routes
  - helmet / cors / rate-limit
  - auth / RBAC / validation / audit hooks
          |
          | SQL (parameterized)
          v
[PostgreSQL + PostGIS]
  - core domain tables
  - spatial_feature geometry ops
  - audit_log and workflow records
  - schema_migrations tracker

[Infra + Ops]
  - Docker Compose production stack (db + migrate + api + nginx)
  - migration runner -> infra/migrations (one-off migrate service)
  - CI gates for lint/typecheck/tests/openapi
```

## Backend Key Modules
- `apps/api/src/app.ts`: app bootstrap, middleware wiring, route mounting, API prefixing.
- `apps/api/src/server.ts`: runtime startup, readiness, graceful shutdown, migrate checks.
- `apps/api/src/middleware/*`: auth, validation, observability, error handling, audit logging.
- `apps/api/src/controllers/*`: auth/projects/features/exports/assignments/photos/categories/notifications/users.
- `apps/api/src/db/migrationRunner.ts`: migration orchestration against `infra/migrations`.
- `apps/api/docs/openapi.yaml`: contract definition.

## Mobile Key Modules
- `apps/mobile/lib/core/providers/providers.dart`: dependency wiring for real vs mock repositories.
- `apps/mobile/lib/features/auth/data/real_auth_repository.dart`: token lifecycle + auth endpoints.
- `apps/mobile/lib/features/projects/data/api_projects_repository.dart`: project data integration.
- `apps/mobile/lib/features/notifications/data/api_notifications_repository.dart`: notification integration.
- `apps/mobile/lib/features/exports/data/api_exports_repository.dart`: export integration.
- `apps/mobile/lib/core/router/app_router.dart`: guarded navigation and shell routing.

## Data and Control Boundaries
- API is sole authority for auth, RBAC, project/feature/export rules.
- Mobile stores session tokens securely and uses API as source of truth.
- Migrations are controlled centrally from `infra/migrations`; no split migration ownership remains.
