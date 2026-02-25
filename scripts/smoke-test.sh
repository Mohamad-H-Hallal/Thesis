#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BASE_URL="${BASE_URL:-http://localhost}"
COMPOSE_FILE="${COMPOSE_FILE:-compose.prod.yml}"
COMPOSE_FILE_ARGS=(-f "$COMPOSE_FILE")

if [[ "${SKIP_UP:-0}" != "1" ]]; then
  docker compose "${COMPOSE_FILE_ARGS[@]}" up -d --build
fi

for i in {1..60}; do
  if curl -fsS "$BASE_URL/health" >/dev/null; then
    break
  fi
  sleep 2
  if [[ "$i" == "60" ]]; then
    echo "Health check did not become ready" >&2
    exit 1
  fi
done

curl -fsS "$BASE_URL/api/v1" >/dev/null
curl -fsS "$BASE_URL/docs/openapi.yaml" >/dev/null

EMAIL="smoke.$(date +%s)@example.com"
PASSWORD="SmokeTest!123"

REGISTER_PAYLOAD=$(cat <<JSON
{"email":"$EMAIL","password":"$PASSWORD","full_name":"Smoke User","role":"admin"}
JSON
)

if curl -fsS -X POST "$BASE_URL/api/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d "$REGISTER_PAYLOAD" >/dev/null; then
  echo "Public register admin attempt was not blocked" >&2
  exit 1
fi

REGISTER_RESPONSE=$(curl -fsS -X POST "$BASE_URL/api/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\",\"full_name\":\"Smoke User\"}")

echo "$REGISTER_RESPONSE" | grep -q '"role":"contributor"'

LOGIN_RESPONSE=$(curl -fsS -X POST "$BASE_URL/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}")

TOKEN=$(echo "$LOGIN_RESPONSE" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
if [[ -z "$TOKEN" ]]; then
  echo "Login token extraction failed" >&2
  exit 1
fi

curl -fsS "$BASE_URL/api/v1/auth/me" -H "Authorization: Bearer $TOKEN" >/dev/null

echo "Smoke test passed against $BASE_URL"
