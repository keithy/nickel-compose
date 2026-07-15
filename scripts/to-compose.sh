#!/usr/bin/env bash
# scripts/to-compose.sh — render compose.ncl and compose.yaml from config.ncl.
#
# config.ncl is a Nickel file that imports a list of fragments
# and returns the result of composer.merge. This script evaluates
# that file and writes two artifacts:
#
#   compose.ncl    # canonical — the merge result as a Nickel record
#   compose.yaml   # derived  — `nickel export --format yaml` from the .ncl
#
# The .ncl is the source of truth: query tools (composer.report.*,
# composer.validation.*) re-import it, and future Nickel-native
# container runtimes can consume it directly. The .yaml is a
# one-way projection for tools that don't speak Nickel.
#
# Usage:
#   ./scripts/to-compose.sh                       # config.ncl -> compose.ncl + compose.yaml
#   ./scripts/to-compose.sh --in my-config.ncl    # custom input
#   ./scripts/to-compose.sh --out merged.yaml     # custom derived path (compose.ncl derived)
#   ./scripts/to-compose.sh --in dev.ncl --out prod.yaml
#   ./scripts/to-compose.sh --engine /path/to/nickel-compose.ncl
#
# The canonical .ncl path is derived from --out by switching the
# extension (.yaml -> .ncl, .yml -> .ncl). Both files land in
# the same directory.
#
# The engine is located via --engine (explicit) or by searching
# common locations (submodule, vendored, script-adjacent). The
# engine's parent directory is added to NICKEL_IMPORT_PATH so the
# config.ncl can simply write `import "nickel-compose.ncl"`
# without a path prefix.

set -euo pipefail

IN="config.ncl"
OUT="compose.yaml"
ENGINE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --in)
      IN="$2"
      shift 2
      ;;
    --out)
      OUT="$2"
      shift 2
      ;;
    --engine)
      ENGINE="$2"
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

if [[ ! -f "$IN" ]]; then
  echo "input file not found: $IN" >&2
  exit 1
fi

case "$OUT" in
  *.yaml|*.yml)
    NCL="${OUT%.*}.ncl"
    ;;
  *)
    echo "--out path must have a .yaml or .yml extension (got: $OUT)" >&2
    echo "the canonical .ncl is derived from --out by switching the extension" >&2
    echo "  e.g. --out merged-compose.yaml  ->  merged-compose.ncl" >&2
    exit 1
    ;;
esac

# Locate the engine if not given. Search order:
#   1. $CWD/nickel-compose/nickel-compose.ncl  (submodule layout)
#   2. $CWD/nickel-compose.ncl                 (vendored at project root)
#   3. $SCRIPT_DIR/../nickel-compose.ncl        (script-adjacent;
#                                               only valid when this
#                                               script lives in a
#                                               nickel-compose checkout)
#   4. NICKEL_COMPOSE_ENGINE env var (explicit override)
if [[ -z "$ENGINE" ]]; then
  ENGINE="${NICKEL_COMPOSE_ENGINE:-}"
fi
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CWD="$(pwd)"
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
  echo "use --engine <path> or set NICKEL_COMPOSE_ENGINE to override" >&2
  exit 1
fi
# The engine's parent directory is the NICKEL_IMPORT_PATH entry.
ENGINE_DIR="$(dirname "$ENGINE")"
# Resolve to absolute for NICKEL_IMPORT_PATH.
[[ "$ENGINE_DIR" != /* ]] && ENGINE_DIR="$(cd "$ENGINE_DIR" && pwd)"

if command -v mise >/dev/null 2>&1; then
  NICKEL="mise exec -- nickel"
else
  NICKEL="nickel"
fi

# Set NICKEL_IMPORT_PATH so the config.ncl can simply write
# `import "nickel-compose.ncl"` without a path prefix. Append
# (don't replace) so the user can keep additional paths in their
# own NICKEL_IMPORT_PATH.
NICKEL_IMPORT_PATH="${NICKEL_IMPORT_PATH:+${NICKEL_IMPORT_PATH}:}${ENGINE_DIR}"
export NICKEL_IMPORT_PATH

$NICKEL eval "$IN" > "$NCL"
$NICKEL export --format yaml "$NCL" | sed -n '2,$p' > "$OUT"

echo "wrote: $NCL (canonical)"
echo "wrote: $OUT (derived from $NCL)"
