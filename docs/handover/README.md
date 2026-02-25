# Handover Evidence Log

Date: 2026-02-24
Workspace: `D:\GIS_APP`

## Backend (apps/api)

Commands executed:
1. `npm run migrate`
2. `npm run openapi:check`
3. `npm run lint`
4. `npm run typecheck`
5. `npm run test:ci`
6. `npm run build`
7. `npm run audit:prod`
8. `npm run dev` + `GET /health` smoke check

Results:
- Migration bootstrap: PASS (`0001`..`0004` applied)
- OpenAPI contract check: PASS
- Lint: PASS
- Typecheck: PASS
- Tests: PASS (`5` suites, `14` tests)
- Build: PASS
- Production dependency audit: PASS (`0` vulnerabilities)
- Dev server smoke check: PASS (`/health` returned `200`)

Artifacts:
- `docs/handover/backend_migrate.log`
- `docs/handover/backend_migration_drift_check.log`
- `docs/handover/backend_openapi_check.log`
- `docs/handover/backend_lint.log`
- `docs/handover/backend_typecheck.log`
- `docs/handover/backend_test.log`
- `docs/handover/backend_build.log`
- `docs/handover/backend_audit_prod.log`
- `docs/handover/backend_dev_server.log`
- `docs/handover/backend_dev_health.log`

## Mobile (apps/mobile)

Commands executed:
1. `flutter pub get`
2. `flutter analyze`
3. `flutter test --coverage`
4. `dart run tool/check_coverage.dart --min-line 19`
5. `flutter build web`
6. `flutter build apk`
7. `flutter doctor -v`

Results:
- Dependency resolution: PASS
- Analyze: PASS
- Tests: PASS
- Coverage gate: PASS (line coverage `19.80%`, threshold `19%`)
- Web build: PASS
- APK build: PASS
- Flutter doctor: PASS (Android toolchain healthy)

Artifacts:
- `docs/handover/mobile_pub_get.log`
- `docs/handover/mobile_analyze.log`
- `docs/handover/mobile_test.log`
- `docs/handover/mobile_coverage_gate.log`
- `docs/handover/mobile_build_web.log`
- `docs/handover/mobile_build_apk.log`
- `docs/handover/flutter_doctor.log`

## Android/Gradle JVM verification

Commands executed (apps/mobile/android):
1. `gradlew -v`
2. `gradlew tasks`
3. `gradlew assembleDebug`

Results:
- `gradlew -v`: PASS (Daemon JVM from `org.gradle.java.home` is JDK 17)
- `gradlew tasks`: PASS
- `gradlew assembleDebug`: PASS

Artifacts:
- `docs/handover/android_gradle_v.log`
- `docs/handover/android_gradle_tasks.log`
- `docs/handover/android_assemble_debug.log`

## Database bootstrap

Command executed:
- `docker compose up -d` in `infra/db`

Result:
- PostGIS container is running.
