# Super Admin Setup

## Required Environment Variables

Set these values before first backend startup:

```env
SUPER_ADMIN_EMAIL=superadmin@gov.lb
SUPER_ADMIN_PASSWORD=ChangeThis!Gov2026
SUPER_ADMIN_FULL_NAME=GIS Super Administrator
```

Where to set them:

- local API run: `apps/api/.env`
- Docker deployment: repo root `.env`
- staging/production: environment variables or Docker secrets-backed env injection

## Bootstrap Behavior

On backend startup, the API checks whether a user exists with `SUPER_ADMIN_EMAIL`.

If it does not exist:

- a new row is inserted into `"user"`
- `role = 'admin'`
- `is_active = true`
- password is hashed before storage in `"user".password_hash`

If it already exists but is not active admin:

- it is corrected back to active admin status

## Security Notes

- Do not commit a real production password.
- Replace `ChangeThis!Gov2026` with a deployment-specific secret before staging or production use.
- The protected super admin identity is enforced by email match against `SUPER_ADMIN_EMAIL`.
- Standard admin endpoints cannot delete or demote the protected super admin.

## Verification

Run:

```powershell
cd D:\GIS_APP\apps\api
npm run migrate
npm run dev
```

Then verify:

- login with `SUPER_ADMIN_EMAIL`
- create an admin through `POST /api/v1/users/admin`
- confirm standard admins receive `403` on the same endpoint
