#!/usr/bin/env bash
# bin/nickel-compose-check.sh — strict typecheck of engine and optional config.
#
# Usage:
#   nickel-compose check [config.ncl]
#
# No arg = engine only. Args are forwarded.

set -euo pipefail

# --- locate engine ---
ENGINE="${NICKEL_COMPOSE_ENGINE:-}"
if [[ -z "$ENGINE" ]]; then
  # Search order: script-adjacent (dev checkout) → NICKEL_COMPOSE_ROOT
  # (mise-installed) → fallback to script-adjacent (which will error
  # below if the file isn't there).
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  for candidate in \
      "$SCRIPT_DIR/../nickel-compose.ncl" \
      "${NICKEL_COMPOSE_ROOT:-}/nickel-compose.ncl"; do
    if [[ -f "$candidate" ]]; then
      ENGINE="$candidate"
      break
    fi
  done
fi
ENGINE="$(cd "$(dirname "$ENGINE")" && pwd)/$(basename "$ENGINE")"

if [[ ! -f "$ENGINE" ]]; then
  echo "engine not found: $ENGINE" >&2
  echo "set NICKEL_COMPOSE_ENGINE to override" >&2
  exit 1
fi

# --- setup ---
if command -v mise >/dev/null 2>&1; then
  NICKEL="mise exec -- nickel"
else
  NICKEL="nickel"
fi

# Set NICKEL_IMPORT_PATH so the user config can `import
# "nickel-compose.ncl"` without a path prefix.
ENGINE_DIR="$(dirname "$ENGINE")"
NICKEL_IMPORT_PATH="${NICKEL_IMPORT_PATH:+${NICKEL_IMPORT_PATH}:}${ENGINE_DIR}"
export NICKEL_IMPORT_PATH

USER_CONFIG="${1:-}"

echo "typecheck: $ENGINE"
$NICKEL typecheck "$ENGINE"

if [[ -n "$USER_CONFIG" ]]; then
  if [[ ! -f "$USER_CONFIG" ]]; then
    echo "user config not found: $USER_CONFIG" >&2
    exit 1
  fi
  echo "typecheck: $USER_CONFIG"
  $NICKEL typecheck "$USER_CONFIG"
fi

echo "ok"