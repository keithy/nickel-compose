#!/usr/bin/env bash
# bin/nickel-compose-run.sh — nickel-run pre-loaded with the engine.
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
#   4. $NICKEL_COMPOSE_ROOT/nickel-compose.ncl       (mise-installed)
#   5. $NICKEL_COMPOSE_ENGINE                        (env override)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Prefer the script-adjacent nickel-run.sh (both live in bin/),
# fall back to PATH (so mise-installed users get the bin/ version).
if [[ -x "$SCRIPT_DIR/nickel-run.sh" ]]; then
  NICKEL_RUN="$SCRIPT_DIR/nickel-run.sh"
else
  NICKEL_RUN="nickel-run.sh"
fi

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
      "$SCRIPT_DIR/../nickel-compose.ncl" \
      "${NICKEL_COMPOSE_ROOT:-}/nickel-compose.ncl"; do
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
  echo "  \$NICKEL_COMPOSE_ROOT/nickel-compose.ncl" >&2
  echo "use NICKEL_COMPOSE_ENGINE to override" >&2
  exit 1
fi

# --- set NICKEL_IMPORT_PATH to include the engine's parent dir ---

ENGINE_DIR="$(dirname "$ENGINE")"
[[ "$ENGINE_DIR" != /* ]] && ENGINE_DIR="$(cd "$ENGINE_DIR" && pwd)"
NICKEL_IMPORT_PATH="${NICKEL_IMPORT_PATH:+${NICKEL_IMPORT_PATH}:}${ENGINE_DIR}"
export NICKEL_IMPORT_PATH

# Forward everything to nickel-run, prepending the engine as
# a NAME=PATH. The engine becomes the free identifier `compose`
# in the expression. The user's own NAME=PATH pairs and `--`
# follow unchanged.
exec "$NICKEL_RUN" "compose=$ENGINE" "$@"
