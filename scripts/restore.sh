#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-compose.prod.yml}"
DUMP_FILE="${1:-}"
EXPECTED_DATABASE="${EXPECTED_DATABASE:-}"

if [[ -z "$DUMP_FILE" ]]; then
  echo "Usage: $0 <dump-file-path>" >&2
  exit 1
fi

if [[ ! -f "$DUMP_FILE" ]]; then
  echo "Dump file not found: $DUMP_FILE" >&2
  exit 1
fi

if [[ "${ALLOW_DESTRUCTIVE_RESTORE:-}" != "I_UNDERSTAND" ]]; then
  echo "Restore refused. Set ALLOW_DESTRUCTIVE_RESTORE=I_UNDERSTAND only during an approved recovery window." >&2
  exit 1
fi

TARGET_DATABASE="$(
  docker compose -f "$COMPOSE_FILE" exec -T db sh -lc 'printf "%s" "$POSTGRES_DB"'
)"
if [[ -z "$EXPECTED_DATABASE" || "$EXPECTED_DATABASE" != "$TARGET_DATABASE" ]]; then
  echo "Restore refused. EXPECTED_DATABASE must exactly match the running target database '$TARGET_DATABASE'." >&2
  exit 1
fi

CHECKSUM_FILE="${DUMP_FILE}.sha256"
if [[ ! -f "$CHECKSUM_FILE" ]]; then
  echo "Checksum file not found: $CHECKSUM_FILE" >&2
  exit 1
fi

(
  cd "$(dirname "$DUMP_FILE")"
  sha256sum -c "$(basename "$CHECKSUM_FILE")"
)
docker compose -f "$COMPOSE_FILE" exec -T db pg_restore --list \
  < "$DUMP_FILE" > /dev/null

echo "Creating a pre-restore backup..."
COMPOSE_FILE="$COMPOSE_FILE" OUTPUT_DIR="${OUTPUT_DIR:-./backups/pre-restore}" \
  bash ./scripts/backup.sh

echo "Restoring dump $DUMP_FILE using ${COMPOSE_FILE}..."
docker compose -f "$COMPOSE_FILE" exec -T db sh -lc \
  'PGPASSWORD="$POSTGRES_PASSWORD" pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --exit-on-error --single-transaction --no-owner --no-privileges' \
  < "$DUMP_FILE"

echo "Restore completed. Running post-restore quick check..."
docker compose -f "$COMPOSE_FILE" exec -T db sh -lc 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT COUNT(*) AS users_count FROM \"user\";"'

echo "Restore verification completed."
