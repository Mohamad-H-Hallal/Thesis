# Final Handover and Deployment Guide

This guide is the practical handover document for the Lebanese GIS Collector app. It summarizes how to run, validate, audit, and deploy the current thesis/demo-ready version. It is intentionally honest: the app has been security-reviewed and hardened using OWASP-style checks, but no app should be described as unhackable.

## 1. Project Overview

The project is a geospatial collection and review platform for Lebanese GIS workflows.

Main parts:
- Flutter app for Android, browser/web, and future iOS.
- Node.js/Express API.
- PostgreSQL/PostGIS spatial database.
- Docker Compose runtime for local/dev/staging-style deployment.
- GIS import/export pipeline with staged review before official map publication.

Current status:
- Browser and Android runtime paths are supported for validation.
- Import workflow is staged: uploaded data is not inserted into official `spatial_feature` until review approval.
- Project Map and Import Map are separated by design.
- Manual validation seed data is available in the current dev database when seeded.

## 2. Architecture

High-level flow:

```text
Flutter mobile/web
  -> REST API /api/v1
  -> PostgreSQL + PostGIS
  -> local/Docker volumes for uploads and generated exports
```

Repository layout:

```text
apps/api      Node.js API, migrations runner, tests, OpenAPI docs
apps/mobile   Flutter app for Android/web/iOS target
infra          database scripts, migrations, nginx config
scripts        release verification, backup/restore, smoke tests
docs           project, phase, handover, and operations documentation
```

Runtime services in Docker:
- `db`: Postgres/PostGIS database.
- `migrate`: one-shot migration service using `infra/migrations`.
- `api`: Node.js production or dev API container.
- `nginx`: reverse proxy and web static file serving.
- `mailpit`: local dev email capture in the dev override stack.

## 3. User Roles

Roles:
- Viewer: can view visible projects and approved official project features.
- Contributor: can request/receive project assignment, collect data on assigned projects, upload imports to assigned projects, and see own import history.
- Admin: manages users, categories, projects, assignments, reviews, imports, exports, and notifications. Admin imports are reviewed by the protected super admin.
- Protected super admin: fixed high-privilege admin identity configured by `SUPER_ADMIN_*`; can create admins and manage admin role promotion/demotion.

Important access rules:
- Project Map shows official approved `spatial_feature` records only.
- Import Map shows staged import features plus approved project context.
- Contributors see their own staged imports; admins can review all permitted imports.
- Staged import features must not leak into Project Map.

## 4. Main Features

Implemented core features:
- Authentication, password reset by email OTP, protected super admin bootstrap.
- Viewer/contributor/admin/super-admin flows.
- Project/category/user/assignment management.
- Project map with approved features, filters, search, geometry support, and Open on Map focus.
- Feature creation with point/line/polygon geometry capture, draft, submit, review, approve/reject.
- GIS import upload with background processing, validation, staging, review, approval/rejection, comments, and notifications.
- Dedicated Import Map with staged features and approved project context.
- Export generation and file download/share/open flows.
- Notifications with unread count and read state.
- Dockerized API/PostGIS/nginx runtime.

## 5. How to Run Locally

### Backend with Docker DB and host API

```powershell
cd D:\GIS_APP
docker compose up -d db
cd apps\api
npm ci
npm run migrate
npm run dev
```

Health checks:

```powershell
Invoke-WebRequest http://localhost:3000/health
Invoke-WebRequest http://localhost:3000/ready
Invoke-WebRequest http://localhost:3000/api/v1
Invoke-WebRequest http://localhost:3000/docs/openapi.yaml
```

### Flutter Web in Chrome

```powershell
cd D:\GIS_APP\apps\mobile
flutter pub get
flutter run -d chrome --web-port 5050 --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL=http://localhost:3000
```

Open:

```text
http://localhost:5050
```

### Android Emulator

```powershell
cd D:\GIS_APP\apps\mobile
adb devices
flutter run -d emulator-5554 --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL=http://10.0.2.2:3000
```

Android emulator notes:
- Use `10.0.2.2` for the host backend.
- For a physical Android device, use the computer LAN IP or `adb reverse tcp:3000 tcp:3000` with `API_BASE_URL=http://127.0.0.1:3000`.

## 6. How to Run with Docker

### Development stack

```powershell
cd D:\GIS_APP
Copy-Item .env.dev.example .env
# Edit .env and set SUPER_ADMIN_EMAIL, SUPER_ADMIN_PASSWORD, SUPER_ADMIN_FULL_NAME.
docker compose up -d --build
```

Useful dev URLs:
- API: `http://localhost:3000`
- API docs: `http://localhost:3000/docs/openapi.yaml`
- Mailpit: `http://localhost:8025`
- Dev DB host port: `54329`

### Production-style compose

```powershell
cd D:\GIS_APP
Copy-Item .env.prod.example .env
# Replace placeholders and set real SMTP, CORS, JWT, DB, and super-admin values.
docker compose -f compose.prod.yml config
docker compose -f compose.prod.yml up -d --build
docker compose -f compose.prod.yml ps
```

Stop:

```powershell
docker compose -f compose.prod.yml down
```

Rebuild:

```powershell
docker compose -f compose.prod.yml up -d --build
```

Logs:

```powershell
docker compose -f compose.prod.yml logs -f api
docker compose -f compose.prod.yml logs -f db
docker compose -f compose.prod.yml logs -f nginx
```

## 7. How to Test

Backend gates:

```powershell
cd D:\GIS_APP\apps\api
npm run openapi:check
npm run lint
npm run typecheck
npm run test:ci
npm run test:perf
npm run audit:prod
npm run release:gate
```

Mobile gates:

```powershell
cd D:\GIS_APP\apps\mobile
flutter analyze
flutter test
flutter build web --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL=http://localhost:3000
flutter build apk --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL=http://10.0.2.2:3000
```

Full repo verification:

```powershell
cd D:\GIS_APP
powershell -ExecutionPolicy Bypass -File .\scripts\verify_all.ps1
```

## 8. Android Build and Release Steps

Debug APK:

```powershell
cd D:\GIS_APP\apps\mobile
flutter build apk --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL=http://10.0.2.2:3000
```

Release APK/AAB checklist:
- Configure production API URL.
- Configure Android signing keystore outside the repo.
- Keep Firebase `google-services.json` local and restricted.
- Run `flutter analyze`, `flutter test`, `flutter build apk`, and optionally `flutter build appbundle`.
- Test on at least one emulator and one physical device before real deployment.

Example production-style build:

```powershell
flutter build appbundle --release --dart-define=APP_FLAVOR=prod --dart-define=API_BASE_URL=https://your-domain.example/api
```

## 9. iOS Requirements and Build Steps

iOS has not been runtime-proven in this Windows environment. Treat iOS as build-target-ready but requiring Mac validation.

Requirements:
- macOS with Xcode.
- Flutter 3.41.2 stable / Dart 3.11.0.
- Apple Developer account for TestFlight/App Store.
- iOS Firebase config if push notifications are enabled.

Typical commands on macOS:

```bash
cd apps/mobile
flutter pub get
flutter analyze
flutter test
flutter build ios --release --dart-define=APP_FLAVOR=prod --dart-define=API_BASE_URL=https://your-domain.example/api
```

Manual iOS checks:
- Login/logout.
- Project Map and Import Map.
- File picker/import upload behavior.
- Photo picker/camera permissions.
- Location permission.
- Push notifications if enabled.

## 10. Browser/Web Build Steps

Run in Chrome:

```powershell
cd D:\GIS_APP\apps\mobile
flutter run -d chrome --web-port 5050 --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL=http://localhost:3000
```

Build web output:

```powershell
flutter build web --dart-define=APP_FLAVOR=prod --dart-define=API_BASE_URL=https://your-domain.example/api
```

If using Docker nginx, place the Flutter web build where the nginx config expects it, or rebuild the image/volume arrangement according to the deployment plan.

Browser validation paths:
- Login.
- Dashboard/shell navigation.
- Users/categories/projects/assignments.
- Project details and Project Map.
- Imports list, Import Details, Import Map.
- Exports and downloads.
- Notifications.

## 11. Backend/API Deployment

Required production settings:
- `NODE_ENV=production`
- Strong `JWT_SECRET_CURRENT` and `JWT_REFRESH_SECRET_CURRENT`.
- Optional previous JWT secrets during rotation.
- `SUPER_ADMIN_EMAIL`, `SUPER_ADMIN_PASSWORD`, `SUPER_ADMIN_FULL_NAME`.
- Real SMTP settings. Production fails closed if mail is not configured correctly.
- `CORS_STRICT=true` and exact `CORS_ORIGIN` values.
- `ENFORCE_HTTPS=true` behind a TLS-terminating proxy.
- `TRUST_PROXY=true` behind nginx/reverse proxy.
- `METRICS_TOKEN` if metrics are enabled.

Deployment flow:

```powershell
docker compose -f compose.prod.yml config
docker compose -f compose.prod.yml up -d --build
docker compose -f compose.prod.yml ps
```

Smoke test:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\smoke-test.ps1 -BaseUrl http://localhost:8088 -ComposeFile compose.prod.yml
```

Production note:
- Use HTTPS at the public edge. The included nginx config is TLS-ready but the active compose setup expects external certificate/domain decisions.

## 12. Database Backup, Reset, and Seed

### Backup

Linux/macOS/Git Bash:

```bash
bash ./scripts/backup.sh
```

PowerShell script for env-file based backup:

```powershell
powershell -ExecutionPolicy Bypass -File .\infra\db\scripts\backup.ps1 -EnvFile .\.env -OutputDir .\backups -PgPort 54329
```

### Restore

```bash
bash ./scripts/restore.sh ./backups/gis_app_YYYYMMDD_HHMMSS.dump
```

PowerShell restore:

```powershell
powershell -ExecutionPolicy Bypass -File .\infra\db\scripts\restore.ps1 -DumpFile .\backups\gis_app_YYYYMMDD_HHMMSS.dump -EnvFile .\.env -PgPort 54329
```

### Safe dev runtime reset

Only use against local/dev data after a backup:

```powershell
docker compose exec api sh -lc "ALLOW_RUNTIME_RESET=true npm run reset:runtime"
```

Safety checks:
- `reset:runtime` refuses to run without `ALLOW_RUNTIME_RESET=true`.
- It refuses production mode.
- It keeps schema/migrations and recreates the protected super admin from env.

### Seed

Development seed:

```powershell
cd apps\api
npm run seed
```

Staging-scale seed:

```powershell
cd apps\api
npm run seed:staging
```

Warning:
- `seed:staging` can be destructive when `STAGING_SEED_RESET=true`; run it only against isolated staging/test databases and with explicit opt-in where required.

## 13. Import Workflow

Import lifecycle:

```text
upload -> uploaded/processing -> pending review or failed -> approved/partially approved/rejected
```

Rules:
- Upload creates a job quickly.
- Parsing/validation/staging runs in background processing.
- Imported data stays in `gis_import_feature` first.
- Official `spatial_feature` records are created only when reviewers approve staged features.
- Contributor imports are reviewed by admins/project admins.
- Admin imports are reviewed by the protected super admin.
- Protected super admin should not use import as a normal data contributor.

Validation controls:
- File checksum stored for duplicate detection.
- Configurable file size and feature count limits.
- CRS validation accepts supported WGS84 path and rejects unknown unsupported CRS.
- Per-feature validation warnings/errors are stored for review.
- Counts are maintained by DB logic and checked through API responses.

User-facing filters:
- All.
- Processing (covers queued/uploaded and processing backend states).
- Pending.
- Approved.
- Partially approved.
- Rejected.
- Failed.

## 14. Map Workflow

Project Map:
- Shows only official approved project features to viewers/public contexts.
- For contributors, own non-approved features are scoped carefully to avoid cross-user leakage.
- Staged imports never appear here until approval creates official features.

Import Map:
- Separate map context for a specific import job.
- Shows staged import features by status.
- Can show approved official project features as context.
- Avoids duplicating a staged feature that already created an approved project context feature.

Large data behavior:
- Uses tile/bbox endpoints, server-side aggregation, and geometry simplification at low zoom.
- Total counts are expected to represent real totals; rendered items may be clustered or summarized for performance.
- In-process cache is used for single-backend import map layer responses with timestamp-based invalidation.

## 15. Open on Map Workflow

Expected behavior for every Open map button:
1. Navigate to the correct map screen.
2. Load project/import map data.
3. Wait for map controller, layout, and target geometry readiness.
4. Focus the camera on the exact geometry.
5. For points, zoom to the point.
6. For lines/polygons, fit the geometry bounds.
7. Select/highlight the feature.
8. Open the feature details sheet.

Routing rules:
- Official approved project feature -> Project Map.
- Staged import feature -> Import Map.
- Import review/staged context -> Import Map.
- Review queue entries that refer to official project features -> Project Map.

This flow is release-critical because users need to understand exactly where a reviewed/imported feature is located.

## 16. Security Checklist

This is an OWASP-style review summary, not a guarantee of being unhackable.

Implemented/hardened controls:
- Password hashing with bcrypt.
- JWT access and refresh token handling with current/previous secret rotation support.
- Protected super admin bootstrap and protected admin-management checks.
- Public signup cannot create admin users.
- Inactive/blocked users are rejected by auth middleware and login checks.
- RBAC on admin, project, feature, import, export, and assignment flows.
- Project assignment access checks for contributor workflows.
- Viewer/contributor read visibility rules for project/feature data.
- Request validation via express-validator and Joi env validation.
- Parameterized SQL through `pg` query parameters; dynamic fragments reviewed for controlled enum/column choices.
- Helmet, CORS configuration, HTTPS enforcement option, and trust-proxy support.
- Auth-specific rate limiting and general API rate limiter.
- Upload extension/size limits for images and GIS files.
- Import file checksum and configurable feature/file limits.
- GIS import staging prevents unreviewed data from entering official map tables.
- Audit logging middleware for sensitive mutations.
- Metrics token requirement when metrics are enabled in production.
- `npm audit --omit=dev` currently reports 0 production vulnerabilities.

Remaining risks and recommended hardening:
- Public static `/uploads` serving exposes files by path if someone knows the randomized filename. Before public production, serve private uploads/import files only through authenticated download endpoints or split public thumbnails/icons from private imports/exports.
- Authenticated requests currently bypass the generic API rate limiter in `app.ts`; add per-user/per-route limits for expensive endpoints before high-volume production.
- Import upload filtering relies mainly on extension and parser validation. Add MIME/magic-number sniffing and optional antivirus scanning for public production.
- Zip/KMZ processing should keep strict limits and should add zip-bomb ratio/entry-count checks before hostile internet deployment.
- Add object storage with signed URLs for production upload/export storage.
- Add centralized logs, alerts, request tracing, and WAF/reverse-proxy protection for public hosting.
- Restrict API docs/metrics/admin endpoints by network or stronger auth in sensitive production deployments.
- Rotate/restrict Firebase mobile API keys if any were ever exposed in old local files or history.
- Enforce HTTPS-only cookies/token storage strategy if the auth model later moves tokens into cookies.

## 17. Estimated Costs

Approximate monthly staging/demo costs:
- Local laptop/demo: free except electricity/internet.
- Small VPS for doctor/team demo: about 5-20 USD/month.
- Managed Postgres/PostGIS: often 15-50+ USD/month depending provider.
- Domain: about 10-20 USD/year.
- SMTP transactional email: often free tier for low volume, then paid.
- Firebase Cloud Messaging: generally free for push messaging.
- Object storage: low cost, commonly cents to a few dollars/month for small test data.
- Monitoring/logging: free tiers exist; production-scale retention is paid.

## 18. Hosting Options

Recommended for doctor/team demo:
1. Single small VPS running Docker Compose.
2. Domain + HTTPS reverse proxy (Caddy, Traefik, Nginx Proxy Manager, or host-managed proxy).
3. PostGIS container volume with scheduled backups.
4. Real SMTP provider.
5. Optional object storage later.

Production path:
- Managed Postgres/PostGIS if budget allows.
- Dedicated API/container host.
- Object storage for uploads/exports.
- Redis and dedicated workers when scaling beyond one API instance.
- Monitoring/alerting and backup verification.

## 19. What Is Free

Usually free for development/demo:
- Flutter SDK.
- Node.js.
- PostgreSQL/PostGIS Docker image.
- Docker Desktop for personal/student use subject to Docker license terms.
- Firebase Cloud Messaging low-volume push.
- Mailpit local email capture.
- Local Chrome/Android emulator testing.
- GitHub public/private repo within plan limits.

## 20. What Requires Payment

Likely paid in real deployment:
- Domain name.
- Public VPS/cloud server.
- Managed database or persistent cloud disk.
- Production SMTP provider beyond free limits.
- App Store / Apple Developer Program for iOS distribution.
- Google Play registration for public Play Store release.
- Monitoring/log retention beyond free limits.
- Cloud object storage at scale.

## 21. Future Production Scaling

Do not add these blindly before the demo. Add when operational need is clear.

Redis:
- Not required for the current single-backend thesis/demo deployment.
- Recommended before multi-instance API deployment, high concurrent map traffic, or shared cache invalidation needs.
- Should be optional: app works without Redis, uses Redis only when `REDIS_URL` is configured, and falls back safely if Redis is unavailable.

Dedicated worker:
- Recommended for large imports/exports and background processing under heavy load.
- Current in-process processing is acceptable for validation but not ideal for multi-instance production.

Cloud storage:
- Recommended for uploads, imports, photos, and exports in production.
- Use private buckets and signed URLs for controlled access.

Monitoring:
- Add uptime checks, API latency dashboards, error alerts, DB disk alerts, and queue/backlog alerts.

AI/GEE classification integration:
- Future thesis or production module only. It is not implemented in the current app release. Do not add until base workflows are stable and data governance, model behavior, validation, and review rules are defined.

## 22. Manual Testing Checklist for Doctor/Team

Use the current Manual Validation seeded data if present.

Seeded users:
- `manual.viewer@gis.local`
- `manual.contributor@gis.local`
- `manual.admin@gis.local`
- `manual.superadmin@gis.local`
- Password: `ManualValidation123!`

Seeded data names:
- `Manual Validation Category`
- `Manual Validation Project`
- `Manual Validation Import - Pending`
- `Manual Validation Import - Approved`
- `Manual Validation Import - Rejected`
- `Manual Validation Import - Failed`

Viewer path:
- Login as viewer.
- Open projects.
- Open Manual Validation Project.
- Open Project Map.
- Confirm only approved point/line/polygon official features are shown.
- Use Open map from any available approved feature card.
- Logout and confirm next login starts from home.

Contributor path:
- Login as contributor.
- Open assigned project.
- Open Project Map.
- Add feature: choose geometry, draw/place it, continue to attributes, save/submit.
- Open imports.
- Open own import details.
- Open Import Map.
- Confirm contributor does not see other contributors' private staged imports.

Admin path:
- Login as admin.
- Check users, categories, projects, assignments.
- Open review queue.
- Open pending/approved/rejected review lists.
- Use Open map from review cards and confirm map focuses and opens details.
- Open imports review queue.
- Open pending/rejected/failed imports.
- Approve/reject staged import features with reason.
- Confirm notifications are sent.

Super-admin path:
- Login as protected super admin.
- Confirm admin management actions are available.
- Review admin-submitted imports if present.
- Confirm protected account cannot be demoted/deleted through normal runtime actions.

Map separation checks:
- Project Map must show official approved `spatial_feature` data only.
- Import Map must show staged `gis_import_feature` data plus approved project context.
- Rejecting a staged import must not create official project features.
- Approving a staged import creates official project features and updates Project Map.

Import checks:
- Pending import opens details and staged feature list.
- Approved import shows approved status/counts.
- Rejected import shows rejection reason.
- Failed import shows validation error.
- Filters: All, Processing, Pending, Approved, Partially approved, Rejected, Failed.

Browser/Android layout checks:
- No red Flutter error screens.
- Buttons have consistent widths in action groups.
- Large screens use multiple columns without awkward centering.
- Small screens stack/wrap controls cleanly.
- No black bottom area, overflow, box/sliver assertions, or null errors.

## Phase 5 Security Audit Notes

Security posture for the current demo is acceptable if deployed behind HTTPS with real secrets and restricted admin accounts. For public production, address the high-priority hardening items in Section 16 before exposing the system to untrusted users at scale.

Highest-priority production hardening:
1. Make private uploaded/import/export files accessible only through authenticated endpoints or private object storage.
2. Add per-user/per-route rate limits for authenticated expensive endpoints.
3. Add upload magic-number checks, archive bomb limits, and optional malware scanning.
4. Add centralized monitoring and alerts.
5. Move large background import/export processing to dedicated workers.

## Phase 6 API Audit Notes

Observed strengths:
- OpenAPI check is part of release gate.
- Pagination exists for major large lists.
- Import and map endpoints use server-side paging/aggregation instead of loading all features blindly.
- Access control checks are present for project read scopes, contributor ownership, import job ownership/review, and export ownership/admin access.
- Bad requests generally return controlled `AppError` responses rather than raw 500s.

Remaining API risks:
- Some SQL builders are dynamic. Reviewed paths use parameter arrays and controlled fragments, but future contributors must keep this discipline.
- Authenticated heavy requests need stricter rate limits before production load.
- Current in-process import map cache is safe for one API instance but not shared across multiple API replicas.
- File download paths are stored server-side and sent through route handlers, but static upload serving should be narrowed for production privacy.
- Large map/import requests should be load-tested with realistic concurrent users before government-scale rollout.

## Phase 7 Docker Audit Notes

Containers:
- `db`: persistent PostGIS database.
- `migrate`: applies `infra/migrations` and exits.
- `api`: Node.js backend, healthchecked, non-root runtime user in production Dockerfile.
- `nginx`: reverse proxy/static web server using unprivileged nginx.
- `mailpit`: dev-only email capture.

Docker strengths:
- Compose stack is simple and reproducible.
- API image is multi-stage and prunes dev dependencies.
- API runs as non-root in production image.
- Nginx uses unprivileged image.
- Secrets can be mounted read-only through `secrets/README.md` and `*_FILE` env patterns.
- DB and API have health/readiness paths.

Docker production risks:
- Images are version-tag pinned but not digest pinned.
- No built-in TLS certificate automation.
- No resource limits specified.
- No automated backup scheduler in compose.
- DB volume is local to the host unless moved to managed storage.
- No Redis/shared cache yet for multi-instance deployments.
- No centralized log aggregation.

Recommended doctor/team staging path:
1. Use one small VPS with Docker Compose.
2. Point a subdomain to the VPS.
3. Put HTTPS in front with Caddy/Traefik/Nginx Proxy Manager or host provider TLS.
4. Configure `.env` from `.env.prod.example` with real secrets and SMTP.
5. Run `docker compose -f compose.prod.yml up -d --build`.
6. Run smoke tests and manual checklist above.
7. Schedule daily `scripts/backup.sh` output to off-server storage.
