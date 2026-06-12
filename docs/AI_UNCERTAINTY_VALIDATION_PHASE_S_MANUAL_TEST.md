# Phase S Manual Runtime Test Report

Date: 2026-06-12

## 1. Setup Used

- Repo: `D:\GIS_APP`
- Branch: `feature/ai-uncertainty-validation-phase-s`
- Runtime API: `http://localhost:3000`
- Flutter web smoke URL: `http://localhost:5050`
- Android device: `emulator-5554`
- Runtime environment: `NODE_ENV=development`
- Runtime DB: local Docker PostGIS container `gis_app-db-1`, `localhost:55578`, database `gis_app`
- AI pipeline root: `D:\AI-ML-pipeline-for-AI-Enhanced-Mobile-GIS`
- AI pipeline mode: `dry_run`
- Project: `South Lebanon Fruit Trees Training Dataset`
- Project ID: `91fbb1ae-3fea-49f7-a057-ada303260534`

## 2. DB Backup Path

`D:\GIS_APP_RUNTIME_BACKUPS\phase_s_manual_20260612_052005.dump`

## 3. Test Users And Roles

No passwords were printed or stored in this report.

- Admin / protected super-admin identity: `ncrsadmin@gmail.com`
- Contributor: `1234@gmail.com`
- Viewer: `12345@gmail.com`

The contributor already had an approved assignment for the target project.

## 4. Task Counts

Before registration:

- `ai_uncertainty_area`: 0 total
- Target project tasks: 0

After Phase S registration:

- Target project tasks: 279
- Status counts: `open=279`
- AI run: `ab28c63f-b2cf-4fd7-b046-393606948357=279`
- Assigned tasks: 0

Duplicate/rerun check after stabilization:

- Before rerun: 279
- Newly registered by rerun: 0
- After rerun: 279
- Sample task row id preserved: yes
- Approved `spatial_feature` count unchanged: yes

After API workflow:

- `open=278`
- `in_review=1`
- Assigned tasks: 1

## 5. Super-Admin Test Result

API/runtime checks passed:

- Opened AI workspace/settings endpoint: 200
- Listed project uncertainty tasks: 200
- Assigned one open task to the contributor: 200
- Assignment changed task status to `assigned`

## 6. Contributor Test Result

API/runtime checks passed:

- Listed own AI validation tasks: 200
- Opened assigned task detail: 200
- Attempted unassigned task detail: 403
- Submitted linked validation feature: 200
- Linked feature status after submit: `pending_review`
- Task status after submit: `in_review`

The linked feature ID is `1e0bc53a-5610-4fee-b172-c2a88685d987`.

## 7. Viewer Permission Result

API/runtime checks passed:

- Project uncertainty task list denied: 403
- Task detail denied: 403
- Task assignment denied: 403

## 8. Android Result

- `flutter build apk --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL=http://10.0.2.2:3000`: passed
- `flutter run -d emulator-5554 --no-resident --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL=http://10.0.2.2:3000`: installed and launched
- Logcat scan: no fatal exceptions, ANR, or Flutter error logs found

Interactive credential entry and map tap validation were not performed from the non-interactive shell.

## 9. spatial_feature Safety Result

Before API workflow:

- Approved `spatial_feature`: 1406
- Total target project `spatial_feature`: 1407

After API workflow:

- Approved `spatial_feature`: 1406
- Total target project `spatial_feature`: 1407
- `ai_validation` source features: `pending_review=1`

Safety confirmations:

- No AI prediction was inserted as approved field data.
- No `spatial_feature` was auto-approved.
- The linked validation feature remains pending normal review.
- Linked task metadata has `auto_approved=false`.
- Linked task metadata has `normal_feature_review_required=true`.

## 10. Issues Found

Found and fixed during this validation:

- The local runtime DB had migration 0027 marked applied from an older checksum and was missing `idx_ai_uncertainty_area_run_feature`. This caused registration reruns to fail with `ON CONFLICT` before local DB repair.
- Registration reruns could refresh non-published `ai_output_layer` rows and cascade-delete/recreate uncertainty tasks, which would lose assignments/statuses. The backend service was patched to preserve existing task rows and re-link them.
- Migration 0027 was patched so `ai_output_layer_id` uses `ON DELETE SET NULL` instead of cascading validation task deletion.

Runtime limitation:

- Browser web server smoke passed with HTTP 200, but full visual login/map click-through was not executed because this session does not provide an interactive browser.

## 11. Ready To Commit

Phase S is ready from backend validation, mobile build/test, API safety, DB task registration, and Android smoke-test perspectives.

Strict browser UX/manual map confirmation still needs a human interactive pass before treating the manual UI checklist as fully complete.
