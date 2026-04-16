#!/bin/sh
set -eu

if [ "$#" -eq 0 ]; then
  echo "usage: dev-entrypoint.sh <command...>" >&2
  exit 1
fi

LOCKFILE="package-lock.json"
STAMP_FILE="node_modules/.package-lock.sha256"

if [ ! -f "$LOCKFILE" ]; then
  echo "missing $LOCKFILE" >&2
  exit 1
fi

mkdir -p node_modules

LOCK_HASH="$(sha256sum "$LOCKFILE" | awk '{print $1}')"
INSTALLED_HASH=""

if [ -f "$STAMP_FILE" ]; then
  INSTALLED_HASH="$(cat "$STAMP_FILE" 2>/dev/null || true)"
fi

if [ "$LOCK_HASH" != "$INSTALLED_HASH" ]; then
  npm ci
  printf '%s' "$LOCK_HASH" > "$STAMP_FILE"
fi

exec "$@"
