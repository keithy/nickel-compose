#!/usr/bin/env bash
# scripts/from-nickel-compose.sh — produce config.ncl from $NICKEL_COMPOSE.
#
# NICKEL_COMPOSE is a colon-separated list. Each token is either:
#   - an env-var reference: $FOO or FOO
#     expanded to the value of that env var (which is itself a
#     colon-separated list of fragment paths)
#   - a literal file path: web.yml or /abs/path/to/x.yml
#     used as-is
# Tokens are concatenated in order. Mixed forms are allowed:
#   NICKEL_COMPOSE='web.yml:$COMPOSE_OVERLAYS:db.yml'
#
# This script writes config.ncl at the project root (or wherever
# --out points) — a Nickel file that imports each fragment and
# returns the result of composer.merge. To render that into
# compose.ncl and compose.yaml, run scripts/to-compose.sh.
#
# Usage:
#   NICKEL_COMPOSE='$COMPOSE_SERVICES:$COMPOSE_OVERLAYS:$COMPOSE_FILE' \
#     ./scripts/from-nickel-compose.sh
#   NICKEL_COMPOSE='base.yml:services/web.yml:services/db.yml' \
#     ./scripts/from-nickel-compose.sh
#   ./scripts/from-nickel-compose.sh --out merged-config.ncl
#
# Migration stages (see WORKFLOW.md):
#   Stage 0: NICKEL_COMPOSE='$COMPOSE_FILE'              (zero work)
#   Stage 1: NICKEL_COMPOSE='$COMPOSE_SERVICES:$COMPOSE_OVERLAYS:$COMPOSE_FILE'
#   Stage 2: freeze into config.ncl, drop the env vars

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NC_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CWD="$(pwd)"

OUT="config.ncl"
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

nickel_compose="${NICKEL_COMPOSE:-}"

if [[ -z "$nickel_compose" ]]; then
  echo "NICKEL_COMPOSE not set" >&2
  echo "Set it to a colon-separated list of fragment paths and/or env-var references:" >&2
  echo "  NICKEL_COMPOSE='base.yml:services/web.yml:overlays/dev.yml'" >&2
  echo "  NICKEL_COMPOSE='\$COMPOSE_SERVICES:\$COMPOSE_OVERLAYS:\$COMPOSE_FILE'" >&2
  echo "  NICKEL_COMPOSE='web.yml:\$COMPOSE_OVERLAYS'" >&2
  exit 1
fi

# Expand $VAR references in NICKEL_COMPOSE and concatenate the
# resulting colon lists in order.
fragments=""
IFS=':' read -ra tokens <<< "$nickel_compose"
for token in "${tokens[@]}"; do
  if [[ -z "$token" ]]; then
    continue
  fi
  if [[ "$token" == \$* ]]; then
    var_name="${token#\$}"
    value="${!var_name:-}"
    if [[ -z "$value" ]]; then
      echo "  NICKEL_COMPOSE references \$$var_name but it's unset or empty" >&2
      continue
    fi
    token="$value"
  fi
  if [[ -z "$fragments" ]]; then
    fragments="$token"
  else
    fragments="$fragments:$token"
  fi
done

if [[ -z "$fragments" ]]; then
  echo "NICKEL_COMPOSE expanded to an empty fragment list" >&2
  echo "NICKEL_COMPOSE was: $nickel_compose" >&2
  exit 1
fi

# Resolve the output path, ensure its parent directory exists, and
# check it doesn't collide with a fragment.
abs_out="$OUT"
[[ "$abs_out" != /* ]] && abs_out="$CWD/$abs_out"
mkdir -p "$(dirname "$abs_out")"
IFS=':' read -ra fragment_paths <<< "$fragments"
for path in "${fragment_paths[@]}"; do
  resolved="$path"
  [[ "$resolved" != /* ]] && resolved="$CWD/$resolved"
  if [[ "$resolved" == "$abs_out" ]]; then
    echo "output path '$OUT' is also a fragment — would clobber source" >&2
    echo "use --out to write to a different path, e.g. --out merged-config.ncl" >&2
    exit 1
  fi
done

# Write the config.ncl. Each fragment becomes a literal import;
# the engine is imported by filename (no path) — to-compose.sh
# sets NICKEL_IMPORT_PATH so the engine can be found regardless
# of where config.ncl lives.
{
  echo "let composer = import \"nickel-compose.ncl\" in"
  echo ""
  echo "let fragments = ["
  for path in "${fragment_paths[@]}"; do
    [[ -z "$path" ]] && continue
    abs="$path"
    [[ "$abs" != /* ]] && abs="$CWD/$abs"
    echo "  import \"$abs\","
  done
  echo "] in"
  echo ""
  echo "composer.merge_with_check fragments"
} > "$OUT"

echo "wrote: $OUT (from NICKEL_COMPOSE: $nickel_compose)"
