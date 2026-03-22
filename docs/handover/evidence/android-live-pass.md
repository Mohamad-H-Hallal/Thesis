# Android Live Pass

Date: `2026-03-21`  
Target commit: `14b85fc`  
Backend target: `http://localhost:3000`  
Android API target: `http://10.0.2.2:3000`

## Environment

- Backend Docker services were up and healthy.
- Android emulator detected and launched as `emulator-5554`.
- Mobile app installed and launched on the emulator with:

```powershell
cd D:\GIS_APP\apps\mobile
flutter run -d emulator-5554 --dart-define=APP_FLAVOR=dev --dart-define=API_BASE_URL=http://10.0.2.2:3000 --no-resident
```

## Passed

- Backend health endpoint returned success.
- Android app launched successfully on emulator.
- Login screen rendered correctly on Android.
- Signup screen rendered correctly on Android.
- Existing admin shell rendered after successful runtime login.
- Existing super-admin shell rendered after runtime env correction.
- Drawer-based management shell was visible on Android.

Evidence screenshots:

- `docs/handover/evidence/android-live-pass/login-screen.png`
- `docs/handover/evidence/android-live-pass/signup-screen.png`
- `docs/handover/evidence/android-live-pass/admin-shell.png`
- `docs/handover/evidence/android-live-pass/admin-projects-shell.png`
- `docs/handover/evidence/android-live-pass/superadmin-shell.png`

## Runtime Issue Found

Protected super-admin state was not exposed at runtime until the local root `.env`
contained the required bootstrap variables:

```env
SUPER_ADMIN_EMAIL=superadmin@gov.lb
SUPER_ADMIN_PASSWORD=ChangeThis!Gov2026
SUPER_ADMIN_FULL_NAME=GIS Super Administrator
```

Without those values, backend login still worked, but `is_protected_super_admin`
resolved to `false`, so the mobile runtime opened the standard admin shell instead
of the super-admin shell.

This was corrected operationally for the live pass by adding those variables to the
local untracked `.env` and restarting the API container.

## Remaining Blocker

This machine could not complete a deterministic end-to-end Android emulator run
through credential entry using automation tooling:

- direct ADB touch/key input was reliable for button navigation, but not for text-field focus
- Flutter integration test input did not persist text into the auth fields on-device

Because of that tooling limitation, this pass did **not** produce a full automated
proof for the entire category -> project -> assignment -> contributor -> feature -> review -> export chain on this machine.

## Verdict From This Pass

- Android runtime boot: `PASS`
- Backend connectivity from emulator: `PASS`
- Admin shell rendering: `PASS`
- Super-admin shell rendering after correct env bootstrap: `PASS`
- Full end-to-end Android workflow proof from the emulator: `BLOCKED`

The repository is still suitable for the next step: a human-driven Android emulator
workflow pass using the documented commands and the screenshots above as baseline.
