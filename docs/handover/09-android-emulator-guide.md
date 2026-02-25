# 09 - Android Emulator Running Guide

## Goal
Run Flutter mobile app against local Docker API from Android emulator.

## Prerequisites
- Android Studio + SDK installed
- Flutter SDK installed and on PATH
- JDK 17 configured for Gradle
- Backend stack reachable from host (recommended: `compose.prod.yml`)

## A) Create Emulator
1. Open Android Studio -> Device Manager.
2. Click Create Device.
3. Choose device profile (e.g., Pixel 6).
4. Select system image (Android 14 / API 34 x86_64 recommended).
5. Finish and start emulator.

CLI alternative:
```powershell
# list available AVDs
emulator -list-avds
# start one
emulator -avd <AVD_NAME>
```

## B) Verify Device Availability
```powershell
adb devices
flutter devices
```
Expected: emulator appears as `emulator-5554` (or similar).

## C) Start Backend
```powershell
cd D:\GIS_APP
Copy-Item .env.dev.example .env
docker compose up -d --build
```

## D) Run Flutter on Emulator
Important: Android emulator cannot use `localhost` for host machine services.
Use `10.0.2.2`.

```powershell
cd D:\GIS_APP\apps\mobile
flutter pub get
flutter run -d emulator-5554 --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL=http://10.0.2.2:3000
```

If using nginx front door on port 8088 in dev compose:
```powershell
flutter run -d emulator-5554 --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL=http://10.0.2.2:8088
```

## E) Flavor Examples
- Staging:
```powershell
flutter run -d emulator-5554 --dart-define=APP_FLAVOR=staging --dart-define=API_BASE_URL=https://staging-api.example.gov.lb
```
- Production:
```powershell
flutter run -d emulator-5554 --dart-define=APP_FLAVOR=prod --dart-define=API_BASE_URL=https://api.example.gov.lb
```

## F) Common Fixes
1. `adb devices` empty:
- Restart adb:
```powershell
adb kill-server
adb start-server
adb devices
```

2. Emulator offline:
- Cold boot device from Device Manager.
- Recreate AVD if system image is corrupted.

3. Cleartext HTTP blocked on Android:
- Debug manifest is configured to allow cleartext traffic for dev.
- If changed, verify `apps/mobile/android/app/src/debug/AndroidManifest.xml` and `.../res/xml/network_security_config.xml`.

4. API unreachable from emulator:
- Ensure backend is listening on host.
- Use `10.0.2.2` (not `localhost`).
- Confirm firewall allows local loopback traffic.

5. Gradle/JDK mismatch:
- Verify Java 17:
```powershell
cd D:\GIS_APP\apps\mobile\android
.\gradlew -v
```

## Screenshot Placeholders
- `[Screenshot: Android Device Manager emulator running]`
- `[Screenshot: flutter run connected to emulator]`
- `[Screenshot: app login screen on emulator]`
