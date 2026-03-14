# AI-Enhanced Geospatial Mobile GIS Collector (Phase 4 UI)

Professional Flutter UI foundation for the Lebanese ministry GIS collector.

![Mobile Coverage Gate](https://img.shields.io/badge/Mobile%20coverage%20gate-enforced-brightgreen)
![Mobile Coverage Threshold](https://img.shields.io/badge/coverage%20threshold-lines%20%E2%89%A5%2019%25-blue)

## Stack
- Flutter (Material 3)
- Riverpod
- GoRouter
- Dio
- flutter_secure_storage

## Run
```bash
flutter pub get
flutter run -d chrome --web-port 5050 --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL=http://localhost:3000
```

Optional UI-only mock mode (dev only):
```bash
flutter run -d chrome --dart-define=APP_FLAVOR=dev --dart-define=USE_MOCK_AUTH=true --dart-define=USE_MOCK_DATA=true
```

## Android JDK Requirement
- Use **JDK 17** for Android Gradle builds/imports.
- Verify active Gradle JVM:
```bash
cd android
./gradlew -v
```

## Quality
```bash
flutter analyze
flutter test --coverage
dart run tool/check_coverage.dart --min-line 19
dart format lib test
```

## Route map
- `/splash`
- `/login`
- `/signup`
- `/forgot-password`
- `/reset-password`
- `/app` (shell with tabs)
- `/app/projects`
- `/app/assigned-projects`
- `/app/map`
- `/app/drafts`
- `/app/submissions`
- `/app/review-queue`
- `/app/exports`
- `/app/notifications`
- `/app/profile`
- `/app/projects/:projectId`
- `/app/add-feature`

## Role-based shell navigation
- Admin:
  - Projects, Map, Review Queue, Exports, Notifications, Profile
- Contributor:
  - Projects, Assigned Projects, Map, Drafts, Submissions, Notifications, Profile
- Viewer:
  - Projects, Notifications, Profile

## Branding assets
- App name in UI: `Lebanon GIS Collector`
- Thesis title branding used in app metadata: `AI-Enhanced Geospatial Mobile GIS Collector`
- Placeholder logo asset: `assets/branding/logo_placeholder.svg`
- App icon placeholder note:
  - Use this logo as temporary source and generate icons later with tooling (e.g. `flutter_launcher_icons`) when final identity is approved.

## Notes
- Auth flow is wired to real backend endpoints by default (`/api/v1/auth/*`).
- Mock auth/data repositories are development-only and controlled by `USE_MOCK_AUTH` and `USE_MOCK_DATA`.
- The map screen now renders a Lebanon basemap with project feature overlays when geometry exists.

## Phase 5 (offline-first core) added
- Local offline store with SQLite on mobile/desktop and memory fallback on web.
- Draft feature save now writes locally and enqueues sync jobs.
- Sync queue supports:
  - idempotency keys
  - retry with exponential backoff
  - max retry cutoff with dead-letter state
  - explicit conflict state (not auto-retried)
  - queue status metrics (actionable vs blocked)
  - conflict handling using local vs remote version
- Background sync timer runs every 25s and can be triggered manually from shell app bar sync action.

## Phase 6 (field collection UX) added
- Assignment-aware project access in collection flow.
- Dynamic attribute form engine rendered from project `collection_form_schema`.
- Geometry capture step with:
  - geometry type policy per project
  - GPS sample capture stub
  - GPS quality and threshold validation
- Photo collection step with:
  - min/max project policy enforcement
  - compression + metadata stubs for each captured photo
- Review step saves draft payload with:
  - schema version
  - geometry/gps metadata
  - photo metadata

## Phase 7 (review workflow) added
- Full draft workflow states:
  - `draft -> submitted -> under_review -> approved/rejected`
- Timeline metadata is persisted per draft in local attributes payload.
- Contributor actions:
  - submit draft from **My Drafts**
  - view workflow timeline in bottom sheet
- Admin actions in **Review Queue**:
  - start review
  - approve with optional note
  - reject with required note
- Notifications center is now fed by workflow transitions.

## Phase 8 (exports + reporting) added
- Export request form with format and filter parameters.
- Async export job queue simulation:
  - `pending -> processing -> completed/failed`
  - background worker tick every 10 seconds + manual tick action
- Export status tracking with:
  - retry for failed jobs
  - download action for completed jobs
  - file size / record count metadata
- Basic reporting dashboard cards:
  - total, pending, completed, failed

## Phase 10 (quality engineering) added
- Sync performance baseline test:
  - `test/core/sync/sync_engine_performance_test.dart`
- Coverage gate tool:
  - `tool/check_coverage.dart` (line coverage threshold currently `>= 19%`)
- Quality gate remains:
  - `flutter analyze`
  - `flutter test --coverage`
  - `dart run tool/check_coverage.dart --min-line 19`
