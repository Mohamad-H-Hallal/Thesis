# Runtime secret files

Do not commit, paste into logs, or send real secrets from this folder. Nested
staging/production `.txt` and `.json` files are ignored by Git. Verify that
with `git check-ignore -v <path>` before creating any value.

The canonical production Compose stack mounts these files by service:

- secrets/db_admin_password.txt
- secrets/db_runtime_password.txt
- secrets/jwt_secret.txt
- secrets/jwt_refresh_secret.txt
- secrets/redis_password.txt
- secrets/metrics_token.txt
- secrets/api_docs_token.txt
- secrets/smtp_password.txt
- secrets/super_admin_password.txt
- secrets/ai_callback_secret.txt
- secrets/firebase-admin/lebanese-gis-collector-df12b-adminsdk.json

For staging, place equivalent values below `secrets/staging/`; never reuse
production credentials. The host paths are selected through the
`*_SECRET_FILE` fields in `.env.prod.example` and `.env.staging.example`.
Container paths are fixed by `compose.prod.yml`; do not put secret values in
Redis URLs or inline Compose environment fields.

Requirements:

- generate independent high-entropy values; do not derive one secret from
  another;
- make each file readable only by the deployment operator/service account;
- use the deployment platform's secret manager in managed staging and
  production; Docker secret files are the single-server reference pattern;
- create `api_docs_token.txt` even while docs are disabled so enabling docs
  later cannot silently fall back to an inline token;
- record only secret version identifiers and rotation dates, never values.

Before Compose validation, confirm all expected files are ignored:

```powershell
git check-ignore -v secrets/staging/db_admin_password.txt
git check-ignore -v secrets/staging/metrics_token.txt
```

For Firebase push delivery in Docker-based environments:
- store the Firebase Admin SDK JSON outside Git, for example:
  - `secrets/firebase-admin/lebanese-gis-collector-df12b-adminsdk.json`
- then set:
  - `PUSH_NOTIFICATIONS_ENABLED=true`
  - `FIREBASE_SERVICE_ACCOUNT_PATH=/run/app-secrets/firebase-admin/lebanese-gis-collector-df12b-adminsdk.json`

Firebase remains an external deployment integration. Mount its credential only
into the API/notification process that needs it; do not mount it into Nginx,
Postgres, Valkey, ClamAV, or monitoring containers.
