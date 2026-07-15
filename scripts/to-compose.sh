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

# Evaluate the config. The config.ncl uses
# `composer.merge_with_check` so the result carries a
# `_check` field. `nickel eval` keeps the field (we need it
# below to set the exit code).
$NICKEL eval "$IN" > "$NCL"

# Build a "clean" version of the merged record (without
# `_check`) and write that as compose.yaml. We do this by
# evaluating a small helper program next to compose.ncl that
# destructures the canonical file and re-emits it without
# `_check`. (The `not_exported` annotation on `_check` is
# stripped by `nickel eval` serialization, so we can't rely
# on it to hide the field from `nickel export`.)
#
# Use a basename-relative import so the helper resolves
# correctly regardless of where compose.ncl lives.
NCL_BASE="$(basename "$NCL")"
HELPER="$(dirname "$NCL")/.strip-check.ncl"
{
  printf 'let s = (import "./%s") in\n' "$NCL_BASE"
  printf '{\n'
  printf '  services = s.services,\n'
  printf '  volumes = s.volumes,\n'
  printf '  networks = s.networks,\n'
  printf '}\n'
} > "$HELPER"
$NICKEL export --format yaml "$HELPER" | sed -n '2,$p' > "$OUT"
rm -f "$HELPER"

# Read _check.ok back out of compose.ncl via a small helper
# file in the same dir (Nickel `import` resolves relative to
# the file containing the import statement).
QUERY="$(dirname "$NCL")/.check-query.ncl"
printf '(import "./%s")._check.ok\n' "$NCL_BASE" > "$QUERY"
ok="$($NICKEL eval "$QUERY" 2>/dev/null || true)"
rm -f "$QUERY"
ok="${ok// /}"  # trim whitespace

echo "wrote: $NCL (canonical)" >&2
echo "wrote: $OUT (derived from $NCL)" >&2

case "$ok" in
  true)
    echo "schema: ok" >&2
    exit 0
    ;;
  false)
    echo "schema: errors found (inspect $NCL._check)" >&2
    exit 1
    ;;
  *)
    echo "schema: not checked (no _check in $NCL)" >&2
    exit 0
    ;;
esac
