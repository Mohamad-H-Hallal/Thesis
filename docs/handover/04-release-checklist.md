# Release Checklist

## Pre-Release Gates
- [x] Database container starts and is healthy.
- [x] Migrations apply on clean DB.
- [x] Migration drift check returns no pending migrations.
- [x] OpenAPI contract check passes.
- [x] Backend lint passes.
- [x] Backend typecheck passes.
- [x] Backend tests pass.
- [x] Backend build passes.
- [x] Backend production dependency audit reports zero vulnerabilities.
- [x] Mobile dependency resolution passes.
- [x] Mobile analyze passes.
- [x] Mobile tests pass with coverage report.
- [x] Mobile coverage gate passes (`>=19%`).
- [x] Mobile web build passes.
- [x] Mobile APK build passes.
- [x] Android Gradle commands pass using JDK 17.

## Verification Commands
Backend:
- `npm run migrate`
- `npm run openapi:check`
- `npm run lint`
- `npm run typecheck`
- `npm run test:ci`
- `npm run build`
- `npm run audit:prod`

Mobile:
- `flutter pub get`
- `flutter analyze`
- `flutter test --coverage`
- `dart run tool/check_coverage.dart --min-line 19`
- `flutter build web`
- `flutter build apk`
- `flutter doctor -v`

Android:
- `.\gradlew -v`
- `.\gradlew tasks`
- `.\gradlew assembleDebug`

## Handover Completion Conditions
- [x] All sprint acceptance criteria satisfied.
- [x] Phase 0-10 engineering scope complete.
- [x] Phase 11 marked partial only for operational rollout/training execution.
- [x] Handover evidence logs archived under `docs/handover/evidence`.

## Release Decision
- Engineering release decision: GO.
- Operational rollout decision: proceed per ministry governance and training schedule.
