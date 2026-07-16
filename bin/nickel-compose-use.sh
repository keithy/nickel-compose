#!/usr/bin/env bash
# bin/nickel-compose-use.sh — render config.ncl to compose.{ncl,yaml}.
#
# Usage:
#   nickel-compose use [config.ncl] [--out <yaml>]
#
# Pure render with full validation recording. The merge engine
# runs schema validation as part of merge_fully_validate and
# attaches the report as `x-check` on the merged record. The
# composed artifact carries that report; `use` does not act on
# it (no exit-code mapping). To enforce the schema, run
# `nickel-compose check` after rendering and inspect
# compose.ncl.x-check.
#
# The first non-flag positional is the config. If none is
# given, fall back to $NICKEL_COMPOSE if set, else ./config.ncl.
# --out changes the derived artifact path; the canonical .ncl
# is derived from --out by switching the extension.

set -euo pipefail

# --- pick config ---

config=""
while [[ $# -gt 0 && "$1" != --* ]]; do
  if [[ -n "$config" ]]; then
    echo "use: only one config path may be given" >&2
    exit 1
  fi
  config="$1"
  shift
done
if [[ -z "$config" ]]; then
  if [[ -n "${NICKEL_COMPOSE:-}" ]]; then
    config="$NICKEL_COMPOSE"
  else
    config="./config.ncl"
  fi
fi

# --- parse --out ---

OUT="compose.yaml"
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

# --- validate inputs ---

if [[ ! -f "$config" ]]; then
  echo "input file not found: $config" >&2
  exit 1
fi

case "$OUT" in
  *.yaml|*.yml)
    NCL="${OUT%.*}.ncl"
    ;;
  *)
    echo "--out path must have a .yaml or .yml extension (got: $OUT)" >&2
    echo "  the canonical .ncl is derived from --out by switching the extension" >&2
    exit 1
    ;;
esac

# --- locate nickel-compose-run ---

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -x "$SCRIPT_DIR/nickel-compose-run.sh" ]]; then
  NICKEL_COMPOSE_RUN="$SCRIPT_DIR/nickel-compose-run.sh"
else
  NICKEL_COMPOSE_RUN="nickel-compose-run.sh"
fi
if [[ ! -x "$NICKEL_COMPOSE_RUN" ]]; then
  echo "nickel-compose-run.sh not found or not executable: $NICKEL_COMPOSE_RUN" >&2
  exit 1
fi

# --- render ---

# merge_fully_validate attaches x-check (schema report) and
# x-source (literal input path) to the result. Both stay in
# the rendered .ncl; Compose ignores x-* fields at runtime,
# so the YAML is valid without a strip step. See AGENTS.md.

# The expression is built in the shell (not single-quoted) so
# the literal $config is inlined into the Nickel string. The
# double-quotes escape whitespace; nickel-run's path
# validation rejects paths with " or \.
expr="compose.merge_fully_validate fragments \"$config\""
"$NICKEL_COMPOSE_RUN" --out "$NCL" \
  fragments="$config" -- \
  "$expr"

# Export compose.yaml from compose.ncl.
if command -v mise >/dev/null 2>&1; then
  NICKEL="mise exec -- nickel"
else
  NICKEL="nickel"
fi
$NICKEL export --format yaml "$NCL" | sed -n '2,$p' > "$OUT"

echo "wrote: $NCL (canonical)" >&2
echo "wrote: $OUT (derived from $NCL)" >&2