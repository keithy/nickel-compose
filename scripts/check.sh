#!/usr/bin/env bash
# scripts/check.sh — strict typecheck of the engine and (optionally)
# a user config.ncl.
#
# Usage:
#   ./scripts/check.sh                # engine only
#   ./scripts/check.sh path/to/config.ncl   # engine + user config
#
# Exits non-zero on any typecheck error. The mise run check task
# wraps this script for convenience.
#
# The engine lives next to this script (in the nickel-compose
# checkout). For a vendored engine elsewhere, set
# NICKEL_COMPOSE_ENGINE to the .ncl path. For a mise-installed
# engine, set NICKEL_COMPOSE_ROOT to the install root.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINE="${NICKEL_COMPOSE_ENGINE:-}"
if [[ -z "$ENGINE" ]]; then
  # Search order: script-adjacent (dev checkout) → NICKEL_COMPOSE_ROOT
  # (mise-installed) → fallback to script-adjacent (which will error
  # below if the file isn't there).
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
