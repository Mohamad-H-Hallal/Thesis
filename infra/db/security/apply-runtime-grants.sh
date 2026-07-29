#!/bin/sh
set -eu

required_file() {
  variable_name="$1"
  eval file_path="\${$variable_name:-}"
  if [ -z "$file_path" ] || [ ! -f "$file_path" ]; then
    echo "Required secret file is unavailable: $variable_name" >&2
    exit 1
  fi
  value=$(tr -d '\r\n' < "$file_path")
  if [ -z "$value" ]; then
    echo "Required secret file is empty: $variable_name" >&2
    exit 1
  fi
  printf '%s' "$value"
}

case "${DB_RUNTIME_USER:-}" in
  ""|*[!A-Za-z0-9_]*)
    echo "DB_RUNTIME_USER must contain only letters, numbers, and underscores" >&2
    exit 1
    ;;
esac

admin_password=$(required_file DB_ADMIN_PASSWORD_FILE)
runtime_password=$(required_file DB_RUNTIME_PASSWORD_FILE)
export PGPASSWORD="$admin_password"

database_ready=false
attempt=1
while [ "$attempt" -le 30 ]; do
  if pg_isready \
    --host "${DB_HOST:-db}" \
    --port "${DB_PORT:-5432}" \
    --username "$DB_OWNER_USER" \
    --dbname "$DB_NAME" >/dev/null 2>&1; then
    database_ready=true
    break
  fi
  attempt=$((attempt + 1))
  sleep 1
done
if [ "$database_ready" != "true" ]; then
  echo "Database did not become reachable for runtime grant application" >&2
  exit 1
fi

psql \
  --host "${DB_HOST:-db}" \
  --port "${DB_PORT:-5432}" \
  --username "$DB_OWNER_USER" \
  --dbname "$DB_NAME" \
  --set ON_ERROR_STOP=1 \
  --set database="$DB_NAME" \
  --set owner_user="$DB_OWNER_USER" \
  --set runtime_user="$DB_RUNTIME_USER" \
  --set runtime_password="$runtime_password" <<'SQL'
SELECT format(
  'CREATE ROLE %I LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION',
  :'runtime_user',
  :'runtime_password'
)
WHERE NOT EXISTS (
  SELECT 1 FROM pg_roles WHERE rolname = :'runtime_user'
)
\gexec

SELECT format(
  'ALTER ROLE %I WITH LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION',
  :'runtime_user',
  :'runtime_password'
)
\gexec

REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE :"database" TO :"runtime_user";
GRANT USAGE ON SCHEMA public TO :"runtime_user";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO :"runtime_user";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO :"runtime_user";
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO :"runtime_user";

ALTER DEFAULT PRIVILEGES FOR ROLE :"owner_user" IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"runtime_user";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner_user" IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO :"runtime_user";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner_user" IN SCHEMA public
  GRANT EXECUTE ON FUNCTIONS TO :"runtime_user";

REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE schema_migrations FROM :"runtime_user";
GRANT SELECT ON TABLE schema_migrations TO :"runtime_user";
SQL

unset PGPASSWORD admin_password runtime_password
echo "Restricted runtime database grants applied."
