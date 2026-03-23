# Phase Recheck After UI Fixes

Date: 2026-03-23

## Summary

This pass closed the remaining UI/runtime gaps around:

- role-specific project navigation
- contributor pending-login enforcement in the mobile UX
- back navigation from non-root routes
- replacement of the last production-path map placeholder with a working project map workspace
- conversion of mobile feature submission from local-only stub behavior to real backend draft/submission calls
- conversion of the review queue from local-only placeholders to backend-backed feature moderation
- redesign of Requests into contributor/project request workflows with pending/rejected handling
- stronger user management with block/unblock, admin promotion/revert boundaries, and search/filter tooling
- richer project map interactions, including feature status filters, detail sheets, and review actions from the map workspace
- Android emulator runtime readiness, including `10.0.2.2` API access and cleartext debug config
- closure of the last major mobile runtime gap: in-app category, project, and assignment provisioning for admin and super-admin users

No new schema redesign was introduced. PostgreSQL/PostGIS remains the source of truth.

## Phase Status

| Phase | Status | Note |
| --- | --- | --- |
| Phase 0 | COMPLETE | Monorepo, CI, lint/typecheck baseline remain intact. |
| Phase 1 | COMPLETE | Scope, RBAC, and governance docs still align with runtime roles. |
| Phase 2 | COMPLETE | Core schema, auth, projects, assignments, notifications, and API contract remain implemented. |
| Phase 3 | COMPLETE | Geospatial API remains in place; mobile map now consumes real project feature data. |
| Phase 4 | COMPLETE | Mobile foundation remains clean-architecture based, role-aware, and now includes in-app admin provisioning flows. |
| Phase 5 | COMPLETE | Offline/sync banner is real state, not placeholder text. |
| Phase 6 | COMPLETE | Feature collection now creates real backend drafts, optional photo uploads, and review submissions from mobile. |
| Phase 7 | COMPLETE | Review workflow now operates on backend `pending_review` features instead of local-only placeholders. |
| Phase 8 | COMPLETE | Export workflow remains implemented and production UI no longer exposes the manual worker-tick control. |
| Phase 9 | COMPLETE | Security hardening remains intact, including pending contributor enforcement and protected metrics behavior. |
| Phase 10 | COMPLETE | Automated tests and quality gates remain green after this pass. |
| Phase 11 | PARTIAL | Engineering deliverables are verified on Android emulator as well; operational rollout, production secrets management, and ministry-side training remain deployment-owner tasks. |

## Placeholder / Mock Recheck

- Removed production-path map placeholder from `apps/mobile/lib/features/map/presentation/screens/map_screen.dart`.
- No offline placeholder banner remains in the production runtime.
- Removed the export worker-tick control from production mobile UI.
- Removed the contributor `Drafts` button from project details until a non-confusing production draft view is exposed.
- Mock auth/data paths remain gated behind `USE_MOCK_AUTH` and `USE_MOCK_DATA` only.
- Production default runtime continues to use the real backend and PostgreSQL data.
- Android `dev` runtime now defaults to `http://10.0.2.2:3000` when `API_BASE_URL` is not provided, removing the last localhost misuse for emulator testing.

## Role Behavior Recheck

- Viewer:
  - can sign up and log in immediately
  - sees `Projects`
  - only receives projects where `project.visible_to_viewers = true` and status is `active` or `completed`
- Contributor:
  - signs up as pending contributor
  - cannot log in until admin approval
  - can request assignment to a public project and see pending/rejected request state
  - sees `Projects` for public/viewer-visible projects
  - sees `Assigned Projects` for approved assignment-based work
- Admin:
  - sees all projects
  - can manage viewer visibility
  - can block/unblock viewer and contributor accounts
  - can approve/reject contributor requests and project assignment requests
  - can review, export, and open the map workspace
- Super admin:
  - remains highest privilege identity by protected service logic
  - now lands in an explicit management shell with visible primary navigation plus drawer access to all admin areas
  - can promote/revert eligible runtime-managed admins and block/unblock any non-protected account

## Critical Gaps Check

No critical engineering blockers were found in this stabilization pass.

Android emulator verification completed on 2026-03-15:

- `flutter analyze` passed
- `flutter test` passed
- `flutter build apk` passed
- `flutter run -d emulator-5554 --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL=http://10.0.2.2:3000 --no-resident` passed
- backend Docker API health responded at `http://localhost:3000/health`

Remaining non-code deployment tasks:

- production secrets provisioning
- server/domain/TLS rollout
- ministry operator training
- staged pilot and support SOP execution
