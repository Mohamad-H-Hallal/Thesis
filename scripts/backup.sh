#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-compose.prod.yml}"
OUTPUT_DIR="${OUTPUT_DIR:-./backups}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUT_FILE="${OUTPUT_DIR}/gis_app_${TIMESTAMP}.dump"
PARTIAL_FILE="${OUT_FILE}.partial"

mkdir -p "$OUTPUT_DIR"
cleanup() {
  rm -f -- "$PARTIAL_FILE"
}
trap cleanup EXIT

echo "Creating backup using ${COMPOSE_FILE}..."
docker compose -f "$COMPOSE_FILE" exec -T db sh -lc \
  'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc --no-owner --no-privileges' \
  > "$PARTIAL_FILE"

if [[ ! -s "$PARTIAL_FILE" ]]; then
  echo "Backup failed: dump is empty." >&2
  exit 1
fi

docker compose -f "$COMPOSE_FILE" exec -T db pg_restore --list \
  < "$PARTIAL_FILE" > /dev/null

mv -- "$PARTIAL_FILE" "$OUT_FILE"
OUT_NAME="$(basename "$OUT_FILE")"
(
  cd "$OUTPUT_DIR"
  sha256sum "$OUT_NAME" > "${OUT_NAME}.sha256"
)

DATABASE_NAME="$(
  docker compose -f "$COMPOSE_FILE" exec -T db sh -lc 'printf "%s" "$POSTGRES_DB"'
)"
BYTES="$(wc -c < "$OUT_FILE" | tr -d ' ')"
SHA256="$(cut -d ' ' -f 1 "${OUT_FILE}.sha256")"
CREATED_AT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf \
  '{"schemaVersion":1,"createdAtUtc":"%s","database":"%s","dumpFile":"%s","bytes":%s,"sha256":"%s","pgRestoreListValidated":true}\n' \
  "$CREATED_AT_UTC" "$DATABASE_NAME" "$OUT_NAME" "$BYTES" "$SHA256" \
  > "${OUT_FILE}.manifest.json"

echo "Backup created: $OUT_FILE"
echo "Checksum: ${OUT_FILE}.sha256"
echo "Manifest: ${OUT_FILE}.manifest.json"
