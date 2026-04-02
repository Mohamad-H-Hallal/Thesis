# 09 - Teammate Setup

## Goal

Clone the repo, start the backend, run the Flutter app on an Android emulator, and test all roles without guessing configuration values.

## Required Versions

- Windows 10/11
- Git
- Docker Desktop
- Node.js 22.x
- Flutter 3.41.2 stable
- Dart 3.11.0
- Android Studio with:
  - Android SDK 36.1.0
  - Android Emulator 36.5.4.0+
  - JDK 17

## Clone

```powershell
git clone <YOUR_REPO_URL>
cd GIS_APP
git checkout handover-ready
```

## Backend Setup

1. Prepare root env:

```powershell
Copy-Item .env.dev.example .env
```

2. Set super admin bootstrap values in `.env`:

```env
SUPER_ADMIN_EMAIL=superadmin@gov.lb
SUPER_ADMIN_PASSWORD=ChangeThis!Gov2026
SUPER_ADMIN_FULL_NAME=GIS Super Administrator
```

3. Start backend stack:

```powershell
docker compose up -d db migrate api
```

Use only the repo-root compose stack for normal runtime testing.
Do not start `infra/db/docker-compose.yml` unless you explicitly need an isolated standalone PostGIS experiment.
The compose API service uses a Docker-specific watcher (`npm run dev:docker`) so backend source changes restart reliably on Windows bind mounts.

4. Verify API health:

```powershell
Invoke-WebRequest http://localhost:3000/health
```

Expected:
- HTTP `200`
- JSON body with `"success": true`

5. Run backend tests against the isolated API test database:

```powershell
cd apps\api
npm ci
npm run test:ci
```

Notes:
- Backend tests use `gis_app_test` on the same compose-backed PostGIS server by default.
- The default local test target is:
  - host `localhost`
  - port `55433`
  - database `gis_app_test`
- Override with `TEST_DB_HOST`, `TEST_DB_PORT`, `TEST_DB_NAME`, `TEST_DB_USER`, `TEST_DB_PASSWORD`, and optional `TEST_DB_ADMIN_DB` if needed.

## Mobile Setup

1. Install dependencies:

```powershell
cd apps\mobile
flutter pub get
```

2. Verify Flutter/Android toolchain:

```powershell
flutter doctor -v
```

3. Confirm Android emulator is available:

```powershell
flutter emulators
```

## Start Android Emulator

Recommended AVD:
- `Pixel_7_Pro_API_34`

Launch:

```powershell
flutter emulators --launch Pixel_7_Pro_API_34
adb kill-server
adb start-server
adb devices
flutter devices
```

Wait until the emulator appears as `device`, not `offline`.

## Run the App on Android Emulator

From `apps/mobile`:

```powershell
flutter run -d emulator-5554 --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL=http://10.0.2.2:3000
```

Important:
- Android emulator must use `10.0.2.2`
- Do not use `localhost`
- If `API_BASE_URL` is omitted in `dev`, Android now defaults to `http://10.0.2.2:3000`

## Optional Web Run

```powershell
flutter run -d chrome --web-port 5050 --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL=http://localhost:3000
```

## Role Testing Quick Start

### Viewer
1. Sign up with role `viewer`
2. Log in immediately
3. Confirm `Projects` tab appears

### Contributor
1. Sign up with role `contributor`
2. Try logging in before approval
3. Confirm blocked message:
   - `Your request is still pending approval. You cannot log in yet.`

### Admin / Super Admin
1. Log in with `SUPER_ADMIN_EMAIL`
2. Approve or reject contributor requests
3. Create admins from the in-app `Create Admin` screen
4. Create categories from `Categories`
5. Create projects from `Projects`
6. Open project assignments and assign contributors/admins
7. Toggle project viewer visibility
8. Continue from the project into map/review/export

## Common Troubleshooting

### 1) Emulator is offline

```powershell
adb kill-server
adb start-server
adb devices
```

If still offline:
- cold boot the AVD from Android Studio Device Manager

### 2) App cannot reach backend

Check:

```powershell
Invoke-WebRequest http://localhost:3000/health
```

Then confirm app run command uses:

```text
http://10.0.2.2:3000
```

### 3) Gradle/JDK issue

```powershell
cd android
.\gradlew -v
```

Expected:
- JVM is Java 17

### 4) Docker DB/API not starting

```powershell
docker compose ps
docker compose logs db
docker compose logs migrate
docker compose logs api
```

Official Docker runtime ports:
- API: `http://localhost:3000`
- DB: `localhost:55433`

### 5) Wrong role behavior in UI

Re-test with a fresh account:
- viewer accounts log in immediately
- contributor accounts remain blocked until approved
- rejected contributors remain blocked from login

## Teammate Verification Checklist

- backend health reachable on `http://localhost:3000/health`
- `apps/api` `npm run test:ci` succeeds
- emulator appears in `flutter devices`
- `flutter run` succeeds with `10.0.2.2`
- viewer flow works
- contributor pending flow works
- admin approval flow works
- map opens
- categories and projects can be provisioned directly from mobile
- project assignments can be managed directly from mobile
- back navigation works from details/map/forms
