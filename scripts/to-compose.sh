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
#
# The canonical .ncl path is derived from --out by switching the
# extension (.yaml -> .ncl, .yml -> .ncl). Both files land in
# the same directory.

set -euo pipefail

IN="config.ncl"
OUT="compose.yaml"
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

if command -v mise >/dev/null 2>&1; then
  NICKEL="mise exec -- nickel"
else
  NICKEL="nickel"
fi

$NICKEL eval "$IN" > "$NCL"
$NICKEL export --format yaml "$NCL" | sed -n '2,$p' > "$OUT"

echo "wrote: $NCL (canonical)"
echo "wrote: $OUT (derived from $NCL)"
