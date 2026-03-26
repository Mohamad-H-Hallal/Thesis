# Testing Checklist

## Executed Verification Evidence

Executed against the current `handover-ready` stabilization pass:

- Docker API: `http://localhost:3000`
- Android emulator API base URL: `http://10.0.2.2:3000`
- Evidence logs:
  - `docs/handover/evidence/live-runtime-verification.log`
  - `docs/handover/evidence/chrome-live-run.log`
  - `docs/handover/evidence/android-live-pass.md`

Executed results:

- `PASS` widget coverage now asserts login failure keeps the user on `LoginScreen`, preserves entered values, and surfaces the auth error:
  - `apps/mobile/test/widget_test.dart`
- `PASS` widget coverage now asserts role-based public/assigned project home behavior and admin viewer-visibility toggle:
  - `apps/mobile/test/features/projects/presentation/project_visibility_widget_test.dart`
- `PASS` widget coverage now asserts logout returns the routed app to login and pending contributor login shows the exact blocked-state message:
  - `apps/mobile/test/features/auth/presentation/auth_navigation_widget_test.dart`
- `PASS` widget coverage now asserts viewer route guards redirect contributor-only shell routes back to projects and signup flows show the correct viewer/contributor success messages:
  - `apps/mobile/test/features/auth/presentation/auth_navigation_widget_test.dart`
- `PASS` widget coverage now asserts duplicate-email signup stays on the signup screen, preserves the typed email, and does not redirect to login:
  - `apps/mobile/test/features/auth/presentation/auth_navigation_widget_test.dart`
- `PASS` widget coverage now asserts the login success notice from signup renders on the login screen:
  - `apps/mobile/test/widget_test.dart`
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
- `PASS` admin and super-admin mobile shells now expose categories, project creation/editing, and project assignment management directly in-app
- `PASS` users management cards are now responsive on Android and expose protected-super-admin markers plus super-admin-only promote/revert actions for eligible users
- `PASS` admin dashboard now includes viewer count and active contributor count from real backend user data
- `PASS` requests screen now renders pending contributor approvals, pending assignment approvals, and rejected contributor history with explicit empty/loading/error states
- `PASS` notifications are session-scoped in mobile state and backend-scoped by `user_id`, preventing cross-user notification bleed
- `PASS` add-feature flow now creates a real `spatial_feature` draft through the backend and can submit it for review
- `PASS` review queue now operates on backend `pending_review` features instead of local-only placeholder data
- `PASS` project map now exposes richer feature interaction with status-based rendering, map centering, and a feature details sheet for attributes, notes, and attached photos
- `PASS` project map now includes a status legend, status filters, full feature details from the map, and admin review actions directly from the feature details sheet
- `PASS` backend project-feature responses are now filtered by role and assignment state, so viewers only receive approved features and contributors only receive approved/pending-review or their own records
- `PASS` export panel no longer exposes the manual worker-tick control in production runtime and now uses Android-safe responsive cards/forms
- `PASS` export submit flow now validates date/BBOX inputs and only shows success after the backend queue request succeeds
- `PASS` mobile requests area is now split into Contributor Requests and Project Requests, each with pending/rejected sections and re-accept actions
- `PASS` users management now supports search, role/state filters, block/unblock, and protected-super-admin-aware admin promotion/revert actions
- `PASS` blocked users now receive `Your account has been blocked.` and cannot log in until unblocked
- `PASS` protected super admin is excluded from app-facing user listings, search/filter results, and assignment eligibility lists
- `PASS` category management now supports search plus optional icon upload from camera/gallery with backend storage
- `PASS` profile now shows backend-managed Help & Support content and allows protected super admin to update it in-app
- `PASS` users, categories, requests, assignments, and projects now use a consistent toggleable filter panel instead of permanently expanded chips
- `PASS` project lifecycle now supports pause, resume, archive, and unarchive back to `completed`
- `PASS` paused projects remain viewable but collection mutations and review submissions are blocked in backend and mobile flow
- `PASS` contributor-only assignment model is enforced; admins are not mixed into project assignment lists
- `PASS` self-deactivate is available to viewer/contributor accounts with assignment-state validation and results in blocked future login until reactivation
- `PASS` notifications now support persisted read/unread handling through the API and remain available on later app open
- `PARTIAL` Android live pass on commit `14b85fc` confirmed runtime launch, backend connectivity, login/signup screen rendering, admin shell rendering, and super-admin shell rendering after env bootstrap correction:
  - `docs/handover/evidence/android-live-pass.md`
  - `docs/handover/evidence/android-live-pass/login-screen.png`
  - `docs/handover/evidence/android-live-pass/signup-screen.png`
  - `docs/handover/evidence/android-live-pass/admin-shell.png`
  - `docs/handover/evidence/android-live-pass/admin-projects-shell.png`
  - `docs/handover/evidence/android-live-pass/superadmin-shell.png`
  - blocker recorded: deterministic emulator text-field automation was not reliable on this machine, so the full category -> project -> assignment -> feature -> review -> export lifecycle still needs one human-driven Android pass
- `PASS` Flutter web launches against live API with:

```powershell
cd D:\GIS_APP\apps\mobile
flutter run -d chrome --web-port 5050 --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL=http://localhost:3000 --no-resident
```

Runtime note:

- The dev Docker stack required `MIGRATIONS_DIR=/workspace/infra/migrations` in `docker-compose.override.yml` for the bind-mounted repo. Without that override, the dev `migrate` service read the wrong path and skipped newer migrations. This is now fixed in the repo.

## Workflow Status Matrix

| Workflow item | Status | Evidence |
| --- | --- | --- |
| Viewer signup/login | WORKING | `apps/api/test/security.auth.test.js`, `apps/mobile/test/features/auth/presentation/auth_navigation_widget_test.dart` |
| Contributor signup pending gate | WORKING | `apps/api/test/security.auth.test.js`, `apps/mobile/test/features/auth/presentation/auth_navigation_widget_test.dart` |
| Contributor rejected login block | WORKING | `apps/api/test/security.auth.test.js` |
| Duplicate email signup handling | WORKING | `apps/mobile/lib/features/auth/presentation/screens/signup_screen.dart`, `apps/mobile/test/features/auth/domain/auth_error_mapper_test.dart` |
| Forgot password / reset password flow | WORKING | `apps/api/src/controllers/auth.controller.ts`, `apps/mobile/lib/features/auth/presentation/screens/forgot_password_screen.dart`, `apps/mobile/lib/features/auth/presentation/screens/reset_password_screen.dart` |
| Category creation/editing | WORKING | `apps/mobile/lib/features/admin/presentation/screens/categories_screen.dart`, `apps/mobile/lib/features/admin/presentation/screens/category_form_screen.dart` |
| Category icon upload | WORKING | `apps/api/src/config/upload.ts`, `apps/mobile/lib/features/admin/presentation/screens/category_form_screen.dart` |
| Project creation/editing | WORKING | `apps/mobile/lib/features/admin/presentation/screens/projects_management_screen.dart`, `apps/mobile/lib/features/admin/presentation/screens/project_form_screen.dart` |
| Project pause/resume/archive/unarchive | WORKING | `apps/api/src/controllers/project.controller.ts`, `apps/mobile/lib/features/admin/presentation/screens/projects_management_screen.dart` |
| Project visibility control | WORKING | `apps/api/test/project.visibility.test.js`, `apps/mobile/test/features/projects/presentation/project_visibility_widget_test.dart` |
| Direct assignment creation | WORKING | `apps/mobile/lib/features/admin/presentation/screens/project_assignments_screen.dart`, `apps/api/test/project.workflow-access.test.js` |
| Contributor project access request | WORKING | `apps/mobile/lib/features/projects/presentation/screens/project_details_screen.dart`, `apps/api/test/project.workflow-access.test.js` |
| Assignment approve/reject/re-approve | WORKING | `apps/mobile/lib/features/admin/presentation/screens/contributor_requests_screen.dart`, `apps/mobile/lib/features/admin/presentation/screens/project_assignments_screen.dart` |
| Unassign/reassign contributor | WORKING | `apps/mobile/lib/features/admin/presentation/screens/project_assignments_screen.dart` |
| User block/unblock | WORKING | `apps/api/test/security.auth.test.js`, `apps/mobile/lib/features/admin/presentation/screens/users_management_screen.dart` |
| Admin promote/revert | WORKING | `apps/api/test/security.auth.test.js`, `apps/mobile/lib/features/admin/presentation/screens/users_management_screen.dart` |
| Self-deactivate | WORKING | `apps/api/src/controllers/auth.controller.ts`, `apps/mobile/lib/features/profile/presentation/screens/profile_screen.dart` |
| Support settings | WORKING | `apps/api/src/controllers/misc.controller.ts`, `apps/mobile/lib/features/profile/presentation/screens/profile_screen.dart` |
| Add feature from project map | WORKING | `apps/mobile/lib/features/map/presentation/screens/map_screen.dart`, `apps/mobile/lib/features/map/presentation/screens/add_feature_screen.dart` |
| Geometry creation | WORKING | `apps/mobile/lib/features/map/presentation/screens/add_feature_screen.dart` |
| Attributes save against schema | WORKING | `apps/api/src/controllers/feature.controller.ts` |
| Photo rule enforcement | WORKING | `apps/api/src/controllers/photo.controller.ts`, existing Phase 11 schema constraints |
| Submit for review | WORKING | `apps/mobile/lib/features/map/presentation/screens/add_feature_screen.dart`, `apps/api/src/controllers/feature.controller.ts` |
| Review approve/reject/re-approve/re-reject | WORKING | `apps/mobile/lib/features/review/presentation/screens/review_queue_screen.dart`, `apps/mobile/lib/features/map/presentation/screens/map_screen.dart` |
| Approved feature persistence and map visibility | WORKING | `apps/api/test/project.workflow-access.test.js`, `apps/mobile/lib/features/map/presentation/screens/map_screen.dart` |
| Export request | WORKING | `apps/mobile/lib/features/exports/presentation/screens/exports_dashboard_screen.dart` |
| Export jobs list | WORKING | `apps/mobile/lib/features/exports/presentation/screens/exports_dashboard_screen.dart` |
| Notifications scoping | WORKING | `apps/api/test/notifications.scope.test.js`, `apps/mobile/lib/core/providers/providers.dart` |
| Notification read/unread persistence | WORKING | `apps/mobile/lib/features/notifications/presentation/controllers/notifications_controller.dart`, `apps/mobile/lib/features/notifications/presentation/screens/notifications_screen.dart` |
| Map filtering/detail/status styles | WORKING | `apps/mobile/lib/features/map/presentation/screens/map_screen.dart` |
| Browser-only visual UX checks | PARTIAL | Manual Chrome pass still needed for final visual confirmation |

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
- duplicate email signup returns a user-facing validation message and no false success
- blocked users cannot be promoted or reverted while blocked
- protected super admin can create admins
- standard admin cannot create admins
- protected super admin is excluded from app-facing user directory responses
- viewer project visibility is enforced by `project.visible_to_viewers`
- paused projects remain viewable but cannot accept feature mutations
- notifications are written for contributor request, approval, and rejection
- support settings can be fetched and updated through `/api/v1/settings/support`
- audit logs exist for registration, approval, rejection, project, assignment, review, export, and user lifecycle flows

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
- contributor public project details expose `Request Access` when the contributor is not yet assigned
- contributor project-request state is visible as pending or rejected in the public project flow
- admin sees review/export sections only
- sync banner shows real queue/sync state only on contributor collection screens where it is useful
- map shows the Lebanon basemap, real feature overlays, and a working `Add Feature` entry path for assigned contributors
- add-feature flow saves a real server draft and can submit it for review
- review queue plus map feature details now support approve/reject and later re-approve/re-reject lifecycle changes
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
- protected super admin does not appear in user search results or assignment candidate lists
- super admin sees `Admin Panel`, `Users`, `Create Admin`, `Requests`, `Projects`, `Assignments`, `Reviews`, `Exports`, `Notifications`, `Profile`
- super admin and admin mobile shells expose primary sections on the bottom bar and the full management list in the drawer
- admin and super-admin can create project categories directly from mobile
- admin and super-admin can create/edit projects directly from mobile using real schema fields
- admin and super-admin can open a project-scoped assignment management screen and assign contributors only
- category create/edit supports search plus optional icon upload
- profile shows Help & Support content, and protected super admin can edit it
- super admin can promote eligible viewers/contributors to admin and revert only toggle-promoted admins to their previous role
- blocked users cannot be promoted/reverted until unblocked
- contributor profile exposes self-deactivate, with confirmation and assignment-state restrictions
- project map shows a clean empty state when no features exist, not a request error box
- add-feature flow can create a server draft, attach selected photos, and submit for review
- project map feature cards and markers open a details sheet showing attributes, status, review notes, and photos
- project map includes status filter chips and a visible map legend so pending/approved/rejected features are clearly distinguished
- review queue decisions update backend feature status and notifications
- blocked users cannot log in until an admin or super admin unblocks them
- users screen supports search, role filters, account-state filters, admin promotion/revert, and block/unblock actions
- requests screen uses simplified top-level labels `Contributor` and `Projects`
- Android debug runtime allows local cleartext traffic for `10.0.2.2`
- if no emulator is attached in CI/local automation, use `flutter build apk` as the build gate and perform the manual checklist below on a human-started emulator

## Manual Flow Order

1. Create or bootstrap super admin.
2. Create a standard admin from the protected super admin account.
3. Create a project category from the mobile admin shell.
4. Create a project from the mobile admin shell.
5. Sign up a contributor from the public UI.
6. Confirm contributor login is rejected while pending.
7. Assign that contributor to the project from mobile.
8. Approve contributor and assignment from admin flow.
9. Confirm contributor can log in and see assigned data only.
10. Sign up another contributor and reject it.
11. Confirm that account remains blocked from login with the rejection message.
12. Log in as super admin and verify the Users screen promote/revert action.
13. Block a viewer or contributor account from Users, confirm login is denied, then unblock it and confirm login works again.
14. Request access to a public project from a contributor account, then approve/reject that project request from Requests.
15. Pause a project, confirm it remains viewable but contributor add/edit/submit actions are blocked, then resume it.
16. Archive a completed project, then unarchive it and confirm it returns to `completed`.
17. Update Help & Support content from protected super admin profile and confirm it appears for a different user.
18. Self-deactivate a contributor account without blocking assignments and confirm later login is denied until reactivation.
19. Log in as admin and confirm only user-scoped notifications are visible.

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
- users screen search/filter chips and action buttons are visually correct on Android
