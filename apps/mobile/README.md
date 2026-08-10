# TerraLeb Mobile App

Professional Flutter app for field GIS collection, offline contribution, AI land intelligence, and validation workflows.

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

Browser notes:
- Chrome and Edge use the same Flutter web build output.
- In local non-production API mode, localhost browser origins on any port are now accepted by CORS.
- If you omit `API_BASE_URL` in `dev`, web defaults to `http://localhost:3000`.

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
- `/app/dashboard`
- `/app/users`
- `/app/admin-create`
- `/app/contributor-requests`
- `/app/projects`
- `/app/assigned-projects`
- `/app/assignments`
- `/app/drafts`
- `/app/submissions`
- `/app/review-queue`
- `/app/exports`
- `/app/notifications`
- `/app/profile`
- `/app/projects/:projectId`
- `/app/projects/:projectId/map`
- `/app/add-feature`

## Role-based shell navigation
- Super Admin:
  - Admin Panel, Users, Create Admin, Requests, Projects, Assignments, Reviews, Exports, Notifications, Profile
- Admin:
  - Projects, Requests, Assignments, Reviews, Exports, Notifications, Profile
- Contributor:
  - Projects, Assigned Projects, Notifications, Profile
- Viewer:
  - Projects, Notifications, Profile

## Branding assets
- App name in UI and platform labels: `TerraLeb`
- Theme-aware light logo: `assets/branding/terraleb_logo_light.png`
- Theme-aware dark logo: `assets/branding/terraleb_logo_dark.png`
- Launcher-icon master: `assets/branding/terraleb_launcher_master.png`
- Transparent adaptive/splash mark: `assets/branding/terraleb_mark_transparent.png`
- In-app branding uses `TerraLebLogo`, which follows the active Flutter theme and supports an explicit brightness override.

## Notes
- Auth flow is wired to real backend endpoints by default (`/api/v1/auth/*`).
- Mock auth/data repositories are development-only and controlled by `USE_MOCK_AUTH` and `USE_MOCK_DATA`.
- The map screen now renders a Lebanon basemap with project feature overlays when geometry exists.

## Phase 5 (offline-first core) added
- Local offline store with SQLite on mobile/desktop and memory fallback on web.
- The project map offline sheet downloads a selected-project offline package:
  - project id/title/category/status
  - collection form schema, classes/lookups, validation rules, photo policy, and cached contribution permissions
  - no project feature layers, approved features, AI predictions, or validation pins
- The Lebanon base/satellite map is a shared offline resource across downloaded projects. The app checks the backend manifest/version while online and reuses the cached base map when it is current. The Download action saves the Lebanon contribution basemap zoom range used for offline field orientation.
  - Current offline contribution basemap range: zoom `7-13` over the configured Lebanon bounds.
  - Expected storage depends on provider tile compression. The current bounds request about `2,279` tiles; typical satellite imagery is roughly `55-135 MB`, but dense imagery can be larger.
- When a downloaded project is opened offline, project map resources and contribution saves use local storage only. If the project package is missing, the app shows: `This project is not downloaded for offline use. Connect to the internet and download it first.`
- Draft feature save now writes locally and enqueues sync jobs.
- Sync queue supports:
  - idempotency keys
  - client-generated offline ids for retry-safe contribution sync
  - retry with exponential backoff
  - max retry cutoff with dead-letter state
  - explicit conflict state (not auto-retried)
  - queue status metrics (actionable vs blocked)
  - conflict handling using local vs remote version
- Sync runs only when network connectivity is available; the controller listens for connectivity changes and triggers sync immediately when the device moves from offline to online. It also checks on app start/resume. The offline sheet exposes manual `Sync now`, and reconnect/periodic sync keeps unsynced items on-device until each item succeeds.
- Background sync timer runs every 25s and can be triggered manually from shell app bar sync action or the project map offline sheet.

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
