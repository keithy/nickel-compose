#!/usr/bin/env bash
# wrappers/from-nickel-compose.sh — render compose.yml from $NICKEL_COMPOSE.
#
# NICKEL_COMPOSE is a colon-separated list of *env-var names*. Each
# named env var is itself a colon-separated list of fragment paths.
# The wrapper reads each, concatenates the fragment lists in order,
# and renders compose.yml by merging them with Compose semantics.
#
# This is the migration workflow: existing projects can keep their
# own env vars (COMPOSE_FILE, COMPOSE_SERVICES, COMPOSE_OVERLAYS)
# and have nickel-compose just orchestrate the assembly.
#
# Usage:
#   NICKEL_COMPOSE='$COMPOSE_SERVICES:$COMPOSE_OVERLAYS:$COMPOSE_FILE' \
#     ./wrappers/from-nickel-compose.sh
#   ./wrappers/from-nickel-compose.sh --out my.yml
#
# Migration stages (see WORKFLOW.md):
#   Stage 0: NICKEL_COMPOSE='$COMPOSE_FILE'              (zero work)
#   Stage 1: NICKEL_COMPOSE='$COMPOSE_SERVICES:$COMPOSE_OVERLAYS:$COMPOSE_FILE'
#   Stage 2: freeze into compose.ncl, drop the env vars
#
# Why NICKEL_COMPOSE instead of COMPOSE_FRAGMENTS:
#
#   COMPOSE_FRAGMENTS takes a literal colon list. NICKEL_COMPOSE
#   takes a list of env-var *names*, each of which holds a
#   colon-separated list. So:
#     NICKEL_COMPOSE='$COMPOSE_SERVICES:$COMPOSE_OVERLAYS'
#     COMPOSE_SERVICES='web.yml:db.yml'
#     COMPOSE_OVERLAYS='dev.yml'
#   = same fragments as
#     COMPOSE_FRAGMENTS='web.yml:db.yml:dev.yml'
#   but with each role separated into its own env var.
#
# Indirection: $VAR in NICKEL_COMPOSE is shell-expanded to that
# var's value at wrapper invocation. So changing COMPOSE_OVERLAYS
# (e.g. switching from dev to prod overlay) is a one-env-var edit;
# NICKEL_COMPOSE stays the same.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NC_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CWD="$(pwd)"

OUT="compose.yml"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      OUT="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

# Read NICKEL_COMPOSE into a local var. The env var itself is
# untouched so subprocesses see whatever the caller exported.
nickel_compose="${NICKEL_COMPOSE:-}"

if [[ -z "$nickel_compose" ]]; then
  echo "NICKEL_COMPOSE not set" >&2
  echo "Set it to a colon-separated list of env-var names, e.g.:" >&2
  echo "  export NICKEL_COMPOSE='\$COMPOSE_SERVICES:\$COMPOSE_OVERLAYS:\$COMPOSE_FILE'" >&2
  exit 1
fi

# Expand $VAR references in NICKEL_COMPOSE and concatenate the
# resulting colon lists in order.
#
#   NICKEL_COMPOSE='$COMPOSE_SERVICES:$COMPOSE_OVERLAYS'
# expands to (with COMPOSE_SERVICES=web.yml:db.yml,
# COMPOSE_OVERLAYS=dev.yml):
#   web.yml:db.yml:dev.yml
fragments=""

# shellcheck disable=SC2162
IFS=':' read -ra var_names <<< "$nickel_compose"
for var_name in "${var_names[@]}"; do
  # Strip the leading $ if present (so both '$FOO' and 'FOO' work).
  var_name="${var_name#\$}"
  if [[ -z "$var_name" ]]; then
    continue
  fi
  # Indirect expansion: get the value of the env var named by $var_name.
  value="${!var_name:-}"
  if [[ -z "$value" ]]; then
    echo "  NICKEL_COMPOSE references \$ $var_name but it's unset or empty" >&2
    continue
  fi
  if [[ -z "$fragments" ]]; then
    fragments="$value"
  else
    fragments="$fragments:$value"
  fi
done

if [[ -z "$fragments" ]]; then
  echo "NICKEL_COMPOSE expanded to an empty fragment list" >&2
  echo "NICKEL_COMPOSE was: $nickel_compose" >&2
  exit 1
fi

# Collision check: refuse to write into a path that's also in the
# expanded fragment list. Otherwise we'd clobber a source file
# mid-render.
abs_out="$OUT"
[[ "$abs_out" != /* ]] && abs_out="$CWD/$abs_out"
IFS=':' read -ra fragment_paths <<< "$fragments"
for path in "${fragment_paths[@]}"; do
  resolved="$path"
  [[ "$resolved" != /* ]] && resolved="$CWD/$resolved"
  if [[ "$resolved" == "$abs_out" ]]; then
    echo "output path '$OUT' is also a fragment — would clobber source" >&2
    echo "use --out to write to a different path, e.g. --out merged-compose.yml" >&2
    exit 1
  fi
done

# Generate a temp config.ncl with literal imports for each fragment.
generate_config() {
  local frags="$1"
  echo "let build = import \"$NC_ROOT/lib/merge.ncl\" in"
  echo ""
  echo "let fragments = ["
  IFS=':' read -ra paths <<< "$frags"
  for path in "${paths[@]}"; do
    [[ -z "$path" ]] && continue
    local abs
    case "$path" in
      /*) abs="$path" ;;
      *)  abs="$CWD/$path" ;;
    esac
    echo "  import \"$abs\","
  done
  echo "] in"
  echo ""
  echo "build fragments"
}

if command -v mise >/dev/null 2>&1; then
  NICKEL="mise exec -- nickel"
else
  NICKEL="nickel"
fi

TMP="$(mktemp -t nickel-compose.XXXXXX.ncl)"
trap 'rm -f "$TMP"' EXIT

generate_config "$fragments" > "$TMP"

$NICKEL export --format yaml "$TMP" | sed -n '2,$p' > "$OUT"

echo "rendered: $OUT (from NICKEL_COMPOSE: $nickel_compose)"