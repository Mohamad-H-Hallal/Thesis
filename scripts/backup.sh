#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-compose.prod.yml}"
OUTPUT_DIR="${OUTPUT_DIR:-./backups}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUT_FILE="${OUTPUT_DIR}/gis_app_${TIMESTAMP}.dump"

mkdir -p "$OUTPUT_DIR"

echo "Creating backup using ${COMPOSE_FILE}..."
docker compose -f "$COMPOSE_FILE" exec -T db sh -lc 'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > "$OUT_FILE"

echo "Backup created: $OUT_FILE"
