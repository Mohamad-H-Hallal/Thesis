# 10 - Android Emulator Testing

## Goal

Run the full mobile workflow against the local backend on Android emulator and verify viewer, contributor, admin, map, navigation, and approval behavior.

## Start the Emulator

```powershell
cd D:\GIS_APP\apps\mobile
flutter emulators
flutter emulators --launch Pixel_7_Pro_API_34
adb kill-server
adb start-server
adb devices
flutter devices
```

Expected:
- emulator appears as `emulator-5554`
- state is `device`

## Start the Backend

```powershell
cd D:\GIS_APP
Copy-Item .env.dev.example .env
docker compose up -d db migrate api
Invoke-WebRequest http://localhost:3000/health
```

Expected:
- backend health returns `200`

## Run Flutter on Android Emulator

```powershell
cd D:\GIS_APP\apps\mobile
flutter run -d emulator-5554 --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL=http://10.0.2.2:3000
```

Important:
- `10.0.2.2` is required for Android emulator access to the host machine
- do not use `localhost`
- if `API_BASE_URL` is omitted in `dev`, Android now defaults to `http://10.0.2.2:3000`

## Viewer Flow

1. Open `Create account`
2. Select `Viewer`
3. Enter:
   - full name
   - phone
   - email
   - password
   - confirm password
4. Submit
5. Verify success message:
   - `Viewer account created successfully. You can log in now.`
6. Log in
7. Verify:
   - app enters shell
   - `Projects` tab is visible
   - only viewer-visible projects appear
8. Open project details
9. Press back
10. Verify return to project list

## Contributor Pending Flow

1. Open `Create account`
2. Select `Contributor`
3. Submit valid data
4. Verify success message:
   - `Your contributor request is pending admin approval.`
5. Try to log in immediately
6. Verify:
   - app stays on login page
   - no session is created
   - message shown:
     - `Your request is still pending approval. You cannot log in yet.`

## Contributor Approved Flow

1. Log in as super admin or admin
2. Approve contributor request
3. Log out
4. Log in as approved contributor
5. Verify:
   - `Projects` tab is visible
   - `Assigned Projects` tab is visible
   - `Projects` contains public/viewer-visible projects only
   - `Assigned Projects` contains approved assignment-based projects only
6. Open assigned project
7. Open map
8. Open add-feature flow
9. Use back navigation to return

## Contributor Rejected Flow

1. Sign up another contributor
2. Log in as admin
3. Reject contributor request
4. Log out
5. Log in as rejected user
6. Verify:
   - login stays on the login screen
   - no session is created
   - message shown:
     - `Your contributor request was rejected. You cannot log in with contributor access.`

## Admin Flow

1. Log in as admin
2. Open `Categories` from the drawer
3. Create a category
4. Open `Projects`
5. Create a project with:
   - category
   - description/objectives
   - status
   - viewer visibility
   - photo policy
   - collection form schema
6. Open `Assignments` on that project
7. Assign a contributor
8. Approve the assignment if it is pending
9. Return to project details and verify:
   - map opens
   - reviews/exports remain reachable
10. Toggle project viewer visibility
11. Verify Lebanon basemap loads
12. Verify no placeholder text is present

## Super Admin Flow

1. Log in as super admin
2. Verify shell contains:
   - `Admin Panel`
   - `Users`
   - `Create Admin`
   - `Requests`
   - `Projects`
   - `Assignments`
   - `Reviews`
   - `Exports`
   - `Notifications`
   - `Profile`
3. Create a new admin from `Create Admin`
4. Create categories and projects directly from the mobile shell
5. Verify the new admin can log in
6. Verify viewer-visible project appears for viewer accounts only when:
   - `visible_to_viewers = true`
   - project status is `active` or `completed`

## Map Verification

Check:
- Lebanon basemap renders
- project selector works on the standalone map page and root map data load
- feature overlays appear if the selected project has geometry
- if no features exist, a real empty-state card appears
- contributor add-feature FAB appears only for assigned contributor projects

## Navigation Verification

Verify back navigation from:
- project details
- map
- add feature
- review queue subflows
- export flow screens

Expected:
- no dead ends
- back returns to the previous logical page

## Error/Validation Verification

### Login
- wrong password -> `Wrong email or password.`
- unknown account -> `This account does not exist.`
- pending contributor -> blocked-state message

### Signup
- invalid email -> inline validation
- weak password -> inline validation
- duplicate email -> API conflict message

## Troubleshooting

### Emulator not listed

```powershell
adb devices
flutter devices
```

### Emulator offline

```powershell
adb kill-server
adb start-server
adb devices
```

### Backend unreachable from app

Confirm:
- backend is healthy on host
- app uses `http://10.0.2.2:3000`

### Cleartext blocked

Debug Android build is configured for local cleartext testing through:
- `apps/mobile/android/app/src/debug/AndroidManifest.xml`
- `apps/mobile/android/app/src/main/res/xml/network_security_config.xml`

## Pass Criteria

- app launches on emulator
- login/signup work
- contributor pending is enforced
- categories can be created from mobile
- projects can be created and edited from mobile
- assignments can be managed from mobile
- viewer/contributor/admin roles render correct tabs
- map works
- back navigation works
- no runtime placeholder text remains in the tested flows
