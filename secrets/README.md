# Docker secrets directory (local pattern)

Do not commit real secrets in this folder.

Create runtime files (not tracked), for example:
- secrets/db_password.txt
- secrets/jwt_secret.txt
- secrets/jwt_secret_current.txt
- secrets/jwt_refresh_secret.txt
- secrets/jwt_refresh_secret_current.txt
- secrets/metrics_token.txt
- secrets/firebase-admin/lebanese-gis-collector-df12b-adminsdk.json

Then set corresponding `*_FILE` environment variables in `.env.prod` / `.env.staging`:
- `POSTGRES_PASSWORD_FILE=/run/secrets/db_password.txt`
- `DB_PASSWORD_FILE=/run/secrets/db_password.txt`
- `JWT_SECRET_FILE=/run/secrets/jwt_secret.txt`
- `JWT_SECRET_CURRENT_FILE=/run/secrets/jwt_secret_current.txt`
- `JWT_REFRESH_SECRET_FILE=/run/secrets/jwt_refresh_secret.txt`
- `JWT_REFRESH_SECRET_CURRENT_FILE=/run/secrets/jwt_refresh_secret_current.txt`
- `METRICS_TOKEN_FILE=/run/secrets/metrics_token.txt`

For Firebase push delivery in Docker-based environments:
- store the Firebase Admin SDK JSON outside Git, for example:
  - `secrets/firebase-admin/lebanese-gis-collector-df12b-adminsdk.json`
- then set:
  - `PUSH_NOTIFICATIONS_ENABLED=true`
  - `FIREBASE_SERVICE_ACCOUNT_PATH=/run/app-secrets/firebase-admin/lebanese-gis-collector-df12b-adminsdk.json`
