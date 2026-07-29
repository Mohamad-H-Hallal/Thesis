#!/bin/sh
set -eu

load_secret_var() {
  var_name="$1"
  file_var_name="${var_name}_FILE"

  eval current_value="\${$var_name:-}"
  eval file_path="\${$file_var_name:-}"

  if [ -n "$current_value" ] && [ -n "$file_path" ]; then
    echo "Both $var_name and $file_var_name are set. Use only one." >&2
    exit 1
  fi

  if [ -n "$file_path" ]; then
    if [ ! -f "$file_path" ]; then
      echo "Secret file for $var_name not found: $file_path" >&2
      exit 1
    fi
    secret_value=$(cat "$file_path")
    export "$var_name=$secret_value"
    unset "$file_var_name"
  fi
}

load_secret_var DB_PASSWORD
load_secret_var JWT_SECRET
load_secret_var JWT_SECRET_CURRENT
load_secret_var JWT_SECRET_PREVIOUS
load_secret_var JWT_REFRESH_SECRET
load_secret_var JWT_REFRESH_SECRET_CURRENT
load_secret_var JWT_REFRESH_SECRET_PREVIOUS
load_secret_var REDIS_PASSWORD
load_secret_var METRICS_TOKEN
load_secret_var API_DOCS_TOKEN
load_secret_var SMTP_PASS
load_secret_var SUPER_ADMIN_PASSWORD
load_secret_var AI_CALLBACK_SECRET
load_secret_var FIREBASE_SERVICE_ACCOUNT_JSON
load_secret_var FIREBASE_SERVICE_ACCOUNT_BASE64

exec "$@"
