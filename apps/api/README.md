# GIS API

![API Coverage Gate](https://img.shields.io/badge/API%20coverage%20gate-enforced-brightgreen)
![API Coverage Threshold](https://img.shields.io/badge/coverage%20threshold-lines%20%E2%89%A5%2030%25-blue)

## Local Setup
1. Use Node LTS 22:
```bash
nvm use
```
2. Copy `.env.example` to `.env` and fill secrets.
   - Default local DB connection is `localhost:55433`, which matches the official root Docker compose stack.
   - Official app runtime uses the root Docker compose stack from the repo root; `infra/db/docker-compose.yml` is maintenance tooling only, not normal app runtime.
3. Install dependencies:
```bash
npm ci
```
4. Run migrations:
```bash
npm run migrate
```
5. Seed development data (optional but recommended):
```bash
npm run seed
```
5b. Seed realistic staging profile (phase 11):
```bash
ALLOW_DESTRUCTIVE_STAGING_RESET=true
npm run seed:staging
npm run staging:verify
```

5c. Reset runtime/business data for a clean retest:
```bash
ALLOW_RUNTIME_RESET=true
npm run reset:runtime
```
- This is destructive.
- It keeps the migrated schema, extensions, enums, and migration tracking intact.
- It clears ordinary runtime data (users, categories, projects, assignments, features, photos, exports, notifications, audit logs, offline map rows, password reset requests, dev seed markers).
- It then re-ensures the protected super admin from `SUPER_ADMIN_*` and resets the singleton `app_support_settings` row to defaults.
- For the compose-backed app runtime, prefer running it inside the API container so it targets the same database as mobile:
  - `docker compose exec api sh -lc "ALLOW_RUNTIME_RESET=true npm run reset:runtime"`
6. Start API (TypeScript dev runner):
```bash
npm run dev
```

## Password Reset Email
- Forgot-password uses:
  - `POST /api/v1/auth/forgot-password`
  - `POST /api/v1/auth/verify-reset-otp`
  - `POST /api/v1/auth/reset-password`
- The flow is:
  - request OTP by email
  - verify the OTP for the same account
  - submit the new password with the verified reset session
- The API never exposes a dev/reset token in UI-facing responses.
- Local Docker development uses Mailpit from the repo root compose stack.
- Mailpit UI: `http://localhost:8025`
- Mailpit SMTP:
  - inside Docker: `mailpit:1025`
  - host-side API commands: `localhost:1025`
- Required config:
  - `SMTP_HOST`
  - `SMTP_PORT`
  - `SMTP_SECURE`
  - `SMTP_USER` / `SMTP_PASS` if your SMTP relay requires auth
  - `SMTP_FROM_EMAIL`
  - optional `SMTP_FROM_NAME`
  - optional `PASSWORD_RESET_TOKEN_EXPIRY_MINUTES`

## Quality Gate
- Lint: `npm run lint`
- Typecheck: `npm run typecheck`
- Build: `npm run build`
- Tests: `npm test`
- OpenAPI contract check: `npm run openapi:check`
- Phase 3 integration tests: `npm run test:phase3`
- Phase 10 e2e workflow test: `npm run test:e2e`
- Phase 10 performance tests: `npm run test:perf`
- Full release gate: `npm run release:gate`
- Phase 11 staging profile seed: `npm run seed:staging`
- Phase 11 staging verification: `npm run staging:verify`
- Phase 11 full staging flow: `npm run phase11:staging`
- Runtime reset for clean retesting: `npm run reset:runtime`
- `seed:staging` is destructive when `STAGING_SEED_RESET=true`; only run it against an isolated DB or with an explicit `ALLOW_DESTRUCTIVE_STAGING_RESET=true` opt-in.
- Seed: `npm run seed`
- CI workflow: `.github/workflows/ci.yml`
- Staging readiness workflow: `.github/workflows/staging-readiness.yml`
- Jest coverage thresholds are enforced in `jest.config.cjs`:
  - coverage is collected from `src/**/*.ts`
  - lines `>= 30%`
  - statements `>= 30%`
  - functions `>= 20%`
  - branches `>= 15%`

## Documentation
- OpenAPI: `docs/openapi.yaml`
- Deployment runbook: `docs/deployment-runbook.md`
- Geospatial performance checks: `docs/phase3-query-plan.sql`

## Phase 3 Geospatial Endpoints
- `GET /api/v1/features/bbox?minLon=...&minLat=...&maxLon=...&maxLat=...&page=1&limit=50`
- `GET /api/v1/features/nearby?lon=...&lat=...&radius=1000&limit=50`

## Phase 9 Operations Endpoints
- `GET /health` (liveness)
- `GET /ready` (readiness + DB check)
- `GET /metrics` (basic app metrics; token-protected when `METRICS_TOKEN` is set)
- `GET /api/v1` (API metadata)

## Phase 9 Security/Ops Notes
- Strict CORS and HTTPS enforcement are configurable via `.env`.
- JWT secret rotation supports current + previous secrets.
- Sensitive routes write sanitized entries to `audit_log`.
- Backup and restore scripts:
  - `infra/db/scripts/backup.ps1`
  - `infra/db/scripts/restore.ps1`
  - these now target the official compose-backed DB on `localhost:55433` by default

## Phase 10 Quality Engineering Notes
- New tests:
  - `test/phase10.e2e.workflow.test.js`
  - `test/phase10.performance.bbox.test.js`
  - `test/phase10.performance.exports.test.js`
- Performance thresholds are configurable by env vars:
  - `PERF_BBOX_FEATURE_COUNT`, `PERF_BBOX_MAX_MS`
  - `PERF_EXPORT_FEATURE_COUNT`, `PERF_EXPORT_MAX_MS`, `PERF_EXPORT_TIMEOUT_MS`
