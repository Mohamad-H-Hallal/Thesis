# Testing Checklist

## Executed Verification Evidence

Executed on 2026-03-20 against the live development runtime:

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
- `PASS` Android-emulator shell now exposes visible primary navigation plus drawer access for admin and super-admin management areas
- `PASS` add-feature flow now creates a real `spatial_feature` draft through the backend and can submit it for review
- `PASS` review queue now operates on backend `pending_review` features instead of local-only placeholder data
- `PASS` export panel no longer exposes the manual worker-tick control in production runtime
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
- rejected contributor remains blocked from login
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
- sync banner shows real queue/sync state only on contributor collection screens where it is useful
- map shows the Lebanon basemap, real feature overlays, and a working `Add Feature` entry path for assigned contributors
- add-feature flow saves a real server draft and can submit it for review
- export panel is scroll-safe on Android screen sizes and no longer shows engineering-only worker controls

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
- pending/rejected contributor login stays on the login screen and shows a visible error message
- viewer sees only admin-published projects
- contributor sees both public `Projects` and `Assigned Projects`
- super admin sees `Admin Panel`, `Users`, `Create Admin`, `Requests`, `Projects`, `Assignments`, `Reviews`, `Exports`, `Notifications`, `Profile`
- super admin and admin mobile shells expose primary sections on the bottom bar and the full management list in the drawer
- project map shows a clean empty state when no features exist, not a request error box
- add-feature flow can create a server draft, attach selected photos, and submit for review
- review queue decisions update backend feature status and notifications
- Android debug runtime allows local cleartext traffic for `10.0.2.2`

## Manual Flow Order

1. Create or bootstrap super admin.
2. Create a standard admin from the protected super admin account.
3. Sign up a contributor from the public UI.
4. Confirm contributor login is rejected while pending.
5. Approve contributor from admin flow.
6. Confirm contributor can log in and see assigned data only.
7. Sign up another contributor and reject it.
8. Confirm that account remains blocked from login with the rejection message.

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
- admin and super-admin drawer entries are visually correct on Android
- map page chips, project selector, feature list, and back navigation are visually correct
