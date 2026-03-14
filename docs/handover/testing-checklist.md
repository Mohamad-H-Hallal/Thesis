# Testing Checklist

## Executed Verification Evidence

Executed on 2026-03-14 against the live development runtime:

- Docker API: `http://localhost:3000`
- Flutter web launch: Chrome on port `5050`
- Evidence logs:
  - `docs/handover/evidence/live-runtime-verification.log`
  - `docs/handover/evidence/chrome-live-run.log`

Executed results:

- `PASS` widget coverage now asserts login failure keeps the user on `LoginScreen`, preserves entered values, and surfaces the auth error:
  - `apps/mobile/test/widget_test.dart`
- `PASS` widget coverage now asserts role-based public/assigned project home behavior and admin viewer-visibility toggle:
  - `apps/mobile/test/features/projects/presentation/project_visibility_widget_test.dart`
- `PASS` widget coverage now asserts logout returns the routed app to login and pending contributor login shows the exact blocked-state message:
  - `apps/mobile/test/features/auth/presentation/auth_navigation_widget_test.dart`
- `PASS` widget coverage now asserts viewer route guards redirect contributor-only shell routes back to projects and signup flows show the correct viewer/contributor success messages:
  - `apps/mobile/test/features/auth/presentation/auth_navigation_widget_test.dart`
- `PASS` widget coverage now asserts viewers remain read-only on project details with no contributor actions:
  - `apps/mobile/test/features/projects/presentation/project_visibility_widget_test.dart`
- `PASS` viewer login with wrong password returns `Wrong email or password.`
- `PASS` login for non-existing account returns `This account does not exist.`
- `PASS` viewer signup creates `role=viewer`, `is_active=true`
- `PASS` contributor signup creates `role=contributor`, `is_active=false`
- `PASS` contributor login is blocked while pending approval
- `PASS` protected super admin login succeeds in Docker runtime
- `PASS` admin-created viewer-visible project appears for viewer
- `PASS` private contributor project is hidden from viewer
- `PASS` viewer receives `403` on private project details
- `PASS` approved contributor sees assigned project only
- `PASS` admin toggle of `visible_to_viewers` immediately changes viewer-visible project list
- `PASS` Flutter web launches against live API with:

```powershell
cd D:\GIS_APP\apps\mobile
flutter run -d chrome --web-port 5050 --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL=http://localhost:3000 --no-resident
```

Runtime note:

- The dev Docker stack required `MIGRATIONS_DIR=/workspace/infra/migrations` in `docker-compose.override.yml` for the bind-mounted repo. Without that override, the dev `migrate` service read the wrong path and skipped newer migrations. This is now fixed in the repo.

## Backend

Run:

```powershell
cd D:\GIS_APP\apps\api
npm run lint
npm run typecheck
npm run migrate
npm run test:ci
npm run build
```

Verify:

- public signup cannot create admin
- viewer signup logs in immediately
- contributor signup is blocked until admin approval
- contributor rejection downgrades role to viewer
- protected super admin can create admins
- standard admin cannot create admins
- viewer project visibility is enforced by `project.visible_to_viewers`
- notifications are written for contributor request, approval, and rejection
- audit logs exist for registration, approval, rejection, project, assignment, review, and export flows

## Chrome

Run:

```powershell
cd D:\GIS_APP\apps\api
npm run dev
```

```powershell
cd D:\GIS_APP\apps\mobile
flutter pub get
flutter run -d chrome --web-port 5050 --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL=http://localhost:3000
```

Verify:

- signup shows inline validation for full name, phone, email, password, confirm password
- contributor signup shows pending-approval success message
- viewer signup shows immediate-login success message
- login stays on the same page on auth failure
- login preserves entered values on auth failure
- login shows user-friendly messages for wrong password, user not found, pending approval, and inactive account
- logout clears session and returns to login
- viewer cannot access contributor/admin shell routes
- viewer home says `Projects` and shows only admin-published projects
- contributor `Projects` shows only admin-published public projects
- contributor `Assigned Projects` shows assigned projects only
- admin sees review/export sections only
- sync banner shows real queue/sync state instead of a placeholder
- map shows the Lebanon basemap and feature overlays or a real empty state if no features exist

## Android Emulator

Run:

```powershell
cd D:\GIS_APP\apps\mobile
flutter run -d emulator-5554 --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL=http://10.0.2.2:3000
```

Executed evidence:

- `docs/handover/evidence/backend-health-android-pass.log`
- `docs/handover/evidence/mobile-run-emulator-android-pass.log`
- `docs/handover/evidence/mobile-build-apk-android-pass.log`

Verify:

- login works against the local API through `10.0.2.2`
- contributor pending/approved/rejected messages match backend responses
- role-based shell navigation matches the signed-in user role
- viewer sees only admin-published projects
- contributor sees both public `Projects` and `Assigned Projects`
- Android debug runtime allows local cleartext traffic for `10.0.2.2`

## Manual Flow Order

1. Create or bootstrap super admin.
2. Create a standard admin from the protected super admin account.
3. Sign up a contributor from the public UI.
4. Confirm contributor login is rejected while pending.
5. Approve contributor from admin flow.
6. Confirm contributor can log in and see assigned data only.
7. Sign up another contributor and reject it.
8. Confirm that account logs in as viewer.

## Remaining Manual Browser Checks

These still require a human pass in Chrome because automated CLI launch cannot visually confirm them:

- login page does not visually reload on auth failure
- email field remains populated after auth failure
- password field behavior matches the chosen UX
- snackbar/banner copy is readable and non-duplicated
- viewer home title renders as `Projects`
- contributor public tab renders as `Projects`
- contributor assigned tab renders as `Assigned Projects`
- admin project details screen shows the viewer-visibility toggle and success snackbar
- sync banner wording and chip values are visually correct in the shell
- map page chips, project selector, and back navigation are visually correct in Chrome
