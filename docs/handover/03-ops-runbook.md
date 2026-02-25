# Operations Runbook (Windows)

## Prerequisites
- Node.js 22.x
- Docker Desktop (Linux containers)
- Flutter stable
- JDK 17 for Android/Gradle

## Required Configuration Files
- DB: `infra/db/.env`
- API: `apps/api/.env`

## Core Environment Variables
- DB: `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`
- API DB: `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`
- API Auth: `JWT_SECRET`, `JWT_REFRESH_SECRET`, rotation vars
- API Routing: `API_VERSION_PREFIX=/api/v1`, `ENABLE_LEGACY_API_PREFIX=true|false`
- API Security/Ops: `CORS_*`, `RATE_LIMIT_*`, `METRICS_ENABLED`, `METRICS_TOKEN`

## Startup Sequence
1. Start database
```powershell
cd infra\db
docker compose up -d
```

2. Run backend
```powershell
cd ..\..\apps\api
npm ci
npm run migrate
npm run lint
npm run typecheck
npm run test:ci
npm run build
npm run dev
```

3. Backend health checks
```powershell
Invoke-WebRequest http://localhost:3000/health
Invoke-WebRequest http://localhost:3000/ready
Invoke-WebRequest http://localhost:3000/docs/openapi.yaml
```

4. Run mobile
```powershell
cd ..\mobile
flutter pub get
flutter analyze
flutter test --coverage
dart run tool/check_coverage.dart --min-line 19
flutter run -d chrome --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL=http://localhost:3000
```

## Android Build Verification (JDK17)
```powershell
cd android
.\gradlew -v
.\gradlew tasks
.\gradlew assembleDebug
```
Expected: Gradle reports JVM/Daemon JVM on Java 17.

## Mock Mode (Dev-only)
Real API integration is default. Mock mode is explicit:
```powershell
flutter run -d chrome --dart-define=USE_MOCK_AUTH=true --dart-define=USE_MOCK_DATA=true
```

## Evidence References
- `docs/handover/evidence/backend-commands.log`
- `docs/handover/evidence/mobile-commands.log`
- `docs/handover/evidence/migrations.log`
- `docs/handover/evidence/ci-screenshots-or-logs.log`
