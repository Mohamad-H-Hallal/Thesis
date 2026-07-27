# GIS API

![API Coverage Gate](https://img.shields.io/badge/API%20coverage%20gate-enforced-brightgreen)
![API Coverage Threshold](https://img.shields.io/badge/coverage%20threshold-lines%20%E2%89%A5%2025%25-blue)

## Local Setup
1. Use Node LTS 22:
```bash
nvm use
```
2. Copy `.env.example` to `.env` and fill secrets.
   - Default local DB connection is `localhost:54329`, which matches the official root Docker compose stack.
   - Official app runtime uses the root Docker compose stack from the repo root; `infra/db/docker-compose.yml` is maintenance tooling only, not normal app runtime.
3. Copy `.env.test.example` to `.env.test` if you need to override the isolated API test DB target.
   - Default test DB connection is `localhost:54329`, database `gis_app_test`.
   - Test commands do not reuse the normal runtime database.
4. Install dependencies:
```bash
npm ci
```
5. Run migrations:
```bash
npm run migrate
```
6. Seed development data (optional but recommended):
```bash
npm run seed
```
6b. Seed realistic staging profile (phase 11):
```bash
ALLOW_DESTRUCTIVE_STAGING_RESET=true
npm run seed:staging
npm run staging:verify
```

6c. Reset runtime/business data for a clean retest:
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
7. Start API (TypeScript dev runner):
```bash
npm run dev
```

Docker dev runtime note:
- The repo-root compose dev stack runs the API with `npm run dev:docker`.
- That command uses `nodemon --legacy-watch` so backend source changes reliably reload on Windows bind-mounted Docker workspaces.
- If you are developing inside Docker, prefer the compose API service instead of starting a second host-side `npm run dev` process.

## API Test Runtime
- Start the shared PostGIS service for local backend tests:
```bash
docker compose up -d db
```
- Prepare the isolated test database explicitly if needed:
```bash
npm run test:db:prepare
```
- Run the CI-equivalent backend suite:
```bash
npm run test:ci
```
- The backend test commands now:
  - use `TEST_DB_*` settings instead of the normal runtime DB
  - default to `localhost:54329` / `gis_app_test`
  - create the test database if it is missing
  - apply migrations before the API test suites run

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
- Two supported runtime modes:
  - Local capture mode:
    - `MAIL_TRANSPORT=mailpit`
    - `PASSWORD_RESET_REQUIRE_REAL_DELIVERY=false`
    - Mailpit UI: `http://localhost:8025`
    - Mailpit SMTP:
      - inside Docker: `mailpit:1025`
      - host-side API commands: `localhost:1025`
  - Real transactional mode:
    - `MAIL_TRANSPORT=smtp`
    - `PASSWORD_RESET_REQUIRE_REAL_DELIVERY=true`
    - `SMTP_HOST`
    - `SMTP_PORT`
    - `SMTP_SECURE`
    - `SMTP_USER` / `SMTP_PASS` if your relay requires auth
    - `SMTP_FROM_EMAIL`
    - optional `SMTP_FROM_NAME`
- In real transactional mode, forgot-password only succeeds if the provider accepts the recipient for delivery.
- The API returns a delivery failure instead of fake success if:
  - required SMTP config is missing
  - the runtime is still using local mail capture
  - `MAIL_TRANSPORT=smtp` but `SMTP_HOST=mailpit`
  - the provider rejects the recipient or fails the send attempt
- Verify the running API container sees the correct config:
  - `docker compose exec api sh -lc "printenv | grep -E '^(MAIL_TRANSPORT|PASSWORD_RESET_REQUIRE_REAL_DELIVERY|SMTP_)' | sort"`
- Verify the active transport in logs:
  - `docker compose logs api --tail 50 | grep \"Password reset mail transport initialized\"`
- Verify a successful provider handoff in logs:
  - `docker compose logs api --tail 50 | grep \"Password reset email accepted by transport\"`
- Required config:
  - `MAIL_TRANSPORT`
  - `PASSWORD_RESET_REQUIRE_REAL_DELIVERY`
  - `SMTP_HOST`
  - `SMTP_PORT`
  - `SMTP_SECURE`
  - `SMTP_USER` / `SMTP_PASS` if your SMTP relay requires auth
  - `SMTP_FROM_EMAIL`
  - optional `SMTP_FROM_NAME`
  - optional `PASSWORD_RESET_TOKEN_EXPIRY_MINUTES`

### Gmail SMTP runtime
- For Gmail SMTP use:
  - `MAIL_TRANSPORT=smtp`
  - `PASSWORD_RESET_REQUIRE_REAL_DELIVERY=true`
  - `SMTP_HOST=smtp.gmail.com`
  - `SMTP_PORT=587`
  - `SMTP_SECURE=false`
  - `SMTP_USER=<your Gmail address>`
  - `SMTP_PASS=<your Gmail app password>`
  - `SMTP_FROM_EMAIL=<same Gmail sender>`
  - optional `SMTP_FROM_NAME=Lebanese GIS Collector`
- Gmail app passwords are displayed in grouped blocks in Google UI. Store the value in `.env` without display-spacing changes elsewhere in the repo.
- For the Docker app runtime, the repo-root `.env` controls the API container.
- For host-side `npm --prefix apps/api ...` commands, `apps/api/.env` controls the host API process.

## Notification delivery runtime
- Android push is supported when all of these are true:
  - `PUSH_NOTIFICATIONS_ENABLED=true`
  - `ANDROID_PUSH_NOTIFICATIONS_ENABLED=true`
  - Firebase Admin SDK secret is mounted and readable by the API
  - the Android app registers a real FCM device token
- iOS push remains intentionally disabled until APNs is configured:
  - `IOS_PUSH_NOTIFICATIONS_ENABLED=false`
  - the API reports this through `GET /api/v1/settings/support`
- When iOS push is disabled or unavailable, the fallback is:
  - persisted in-app notifications
  - notification email delivery through SMTP

## Remaining manual configuration
- Android real-device push:
  - connect a physical Android phone
  - grant notification permission
  - log in once so the device token registers
  - trigger a notification and verify foreground, background, closed-app, and tap-open behavior
- iOS push:
  - blocked until Apple Developer membership and APNs configuration are available
  - keep `IOS_PUSH_NOTIFICATIONS_ENABLED=false` until then
- Security:
  - Firebase mobile app config files are no longer tracked in Git
  - the Firebase Admin SDK JSON is not committed
  - the earlier Firebase mobile config exposure still exists in Git history from older commits, so you still need to restrict or rotate the Firebase app API keys in Google Cloud
  - recommended restrictions:
    - Android key: restrict to the app package name and signing SHA-1/SHA-256
    - iOS key: restrict to the bundle ID
    - allow only the Firebase APIs actually required by the app

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
  - lines `>= 25%`
  - statements `>= 25%`
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
  - these now target the official compose-backed DB on `localhost:54329` by default

## Phase 10 Quality Engineering Notes
- New tests:
  - `test/phase10.e2e.workflow.test.js`
  - `test/phase10.performance.bbox.test.js`
  - `test/phase10.performance.exports.test.js`
- Performance thresholds are configurable by env vars:
  - `PERF_BBOX_FEATURE_COUNT`, `PERF_BBOX_MAX_MS`
  - `PERF_EXPORT_FEATURE_COUNT`, `PERF_EXPORT_MAX_MS`, `PERF_EXPORT_TIMEOUT_MS`
