#!/usr/bin/env bash
# scripts/nickel-compose-run.sh — nickel-run pre-loaded with the engine.
#
# Thin wrapper around nickel-run. Adds:
#   - `compose` as a free identifier in the expression (the
#     imported engine; not wrapped in a `run` record)
#   - NICKEL_IMPORT_PATH set to the engine's parent dir (so the
#     engine can resolve any future sub-imports without users
#     touching the environment)
#
# Usage is identical to nickel-run, except the user does NOT pass
# the engine as a NAME=PATH. Instead they reference it as `compose`
# inside the expression:
#
#   nickel-compose-run cfg=config.ncl -- \
#     'compose.merge_with_source cfg _paths.cfg'
#
# Engine location (search order):
#   1. $CWD/nickel-compose/nickel-compose.ncl        (submodule)
#   2. $CWD/nickel-compose.ncl                       (vendored)
#   3. $SCRIPT_DIR/../nickel-compose.ncl             (script-adjacent)
#   4. $NICKEL_COMPOSE_ENGINE                        (env override)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NICKEL_RUN="$SCRIPT_DIR/nickel-run.sh"

if [[ ! -x "$NICKEL_RUN" ]]; then
  echo "nickel-run.sh not found or not executable: $NICKEL_RUN" >&2
  exit 1
fi

# --- locate engine ---

CWD="$(pwd)"
ENGINE="${NICKEL_COMPOSE_ENGINE:-}"
if [[ -z "$ENGINE" ]]; then
  for candidate in \
      "$CWD/nickel-compose/nickel-compose.ncl" \
      "$CWD/nickel-compose.ncl" \
      "$SCRIPT_DIR/../nickel-compose.ncl"; do
    if [[ -f "$candidate" ]]; then
      ENGINE="$candidate"
      break
    fi
  done
fi
if [[ -z "$ENGINE" || ! -f "$ENGINE" ]]; then
  echo "engine not found: looked for nickel-compose.ncl in" >&2
  echo "  \$CWD/nickel-compose/nickel-compose.ncl" >&2
  echo "  \$CWD/nickel-compose.ncl" >&2
  echo "  \$SCRIPT_DIR/../nickel-compose.ncl" >&2
  echo "use NICKEL_COMPOSE_ENGINE to override" >&2
  exit 1
fi

# --- set NICKEL_IMPORT_PATH to include the engine's parent dir ---

ENGINE_DIR="$(dirname "$ENGINE")"
[[ "$ENGINE_DIR" != /* ]] && ENGINE_DIR="$(cd "$ENGINE_DIR" && pwd)"
NICKEL_IMPORT_PATH="${NICKEL_IMPORT_PATH:+${NICKEL_IMPORT_PATH}:}${ENGINE_DIR}"
export NICKEL_IMPORT_PATH

# --- forward to nickel-run, prepending compose=ENGINE ---

# Find the -- separator and inject compose=ENGINE before it, leaving
# everything after -- untouched (the expression).
ARGS=()
SEEN_SEP=0
for arg in "$@"; do
  if [[ "$SEEN_SEP" -eq 0 ]]; then
    if [[ "$arg" == "--" ]]; then
      ARGS+=("compose=$ENGINE" "--")
      SEEN_SEP=1
    else
      ARGS+=("$arg")
    fi
  else
    ARGS+=("$arg")
  fi
done

exec "$NICKEL_RUN" "${ARGS[@]}"
