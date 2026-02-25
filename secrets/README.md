# Docker secrets directory (local pattern)

Do not commit real secrets in this folder.

Create runtime files (not tracked), for example:
- secrets/db_password.txt
- secrets/jwt_secret.txt
- secrets/jwt_secret_current.txt
- secrets/jwt_refresh_secret.txt
- secrets/jwt_refresh_secret_current.txt
- secrets/metrics_token.txt

Then set corresponding `*_FILE` environment variables in `.env.prod` / `.env.staging`:
- `POSTGRES_PASSWORD_FILE=/run/secrets/db_password.txt`
- `DB_PASSWORD_FILE=/run/secrets/db_password.txt`
- `JWT_SECRET_FILE=/run/secrets/jwt_secret.txt`
- `JWT_SECRET_CURRENT_FILE=/run/secrets/jwt_secret_current.txt`
- `JWT_REFRESH_SECRET_FILE=/run/secrets/jwt_refresh_secret.txt`
- `JWT_REFRESH_SECRET_CURRENT_FILE=/run/secrets/jwt_refresh_secret_current.txt`
- `METRICS_TOKEN_FILE=/run/secrets/metrics_token.txt`
