#!/usr/bin/env bash
# scripts/to-compose.sh — render compose.ncl and compose.yaml from config.ncl.
#
# config.ncl is a Nickel file containing a bare list of fragments:
#
#   [
#     import "./base.yml",
#     import "./services/web.yml",
#   ]
#
# No engine import, no merge call — this script wraps the list with
# the engine and calls composer.merge_with_source at eval time.
# Two artifacts are written:
#
#   compose.ncl    # canonical — the merged record as a Nickel term
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
#
# Implementation: this script is a thin orchestrator. The actual
# eval happens in scripts/nickel-compose-run.sh, which pre-loads
# the engine as `compose` and runs the standard merge expression
# against the user's fragment list.

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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NICKEL_COMPOSE_RUN="$SCRIPT_DIR/nickel-compose-run.sh"

if [[ ! -x "$NICKEL_COMPOSE_RUN" ]]; then
  echo "nickel-compose-run.sh not found or not executable: $NICKEL_COMPOSE_RUN" >&2
  exit 1
fi

# Wrap the user's bare fragment list with the engine and call
# merge_with_source, writing the result to compose.ncl. The
# engine sets x-source to the literal path the user passed
# (so the artifact is reproducible across machines), and
# x-check to the schema report. The absolute path is still
# available via _paths.fragments for tools that need it.
# The expression produces a record — we keep it in Nickel's
# native form (not yaml) so the .ncl remains re-importable.
#
# The expression is built in the shell (not single-quoted)
# so the literal "$IN" gets inlined into the Nickel string.
# The double-quotes around $IN escape any whitespace in the
# path; the nickel-run path validation rejects paths with
# double-quote or backslash, so we don't have to escape those.
expr="compose.merge_with_source fragments \"$IN\""
"$NICKEL_COMPOSE_RUN" --out "$NCL" \
  fragments="$IN" -- \
  "$expr"

# Export compose.yaml from compose.ncl. The `x-check` field
# stays in the output, but Compose silently ignores any `x-*`
# field at runtime, so the rendered YAML is valid Compose
# without a strip step. The Compose spec reserves `x-*` as
# extension fields; see AGENTS.md for the rationale.
if command -v mise >/dev/null 2>&1; then
  NICKEL="mise exec -- nickel"
else
  NICKEL="nickel"
fi
$NICKEL export --format yaml "$NCL" | sed -n '2,$p' > "$OUT"

# Read x-check.ok from compose.ncl for the exit code.
QUERY="$(dirname "$NCL")/.check-query.ncl"
NCL_BASE="$(basename "$NCL")"
printf '(import "./%s")."x-check".ok\n' "$NCL_BASE" > "$QUERY"
ok="$($NICKEL eval "$QUERY" 2>/dev/null || true)"
rm -f "$QUERY"
ok="${ok// /}"

echo "wrote: $NCL (canonical)" >&2
echo "wrote: $OUT (derived from $NCL)" >&2

case "$ok" in
  true)
    echo "schema: ok" >&2
    exit 0
    ;;
  false)
    echo "schema: errors found (inspect $NCL.x-check)" >&2
    exit 1
    ;;
  *)
    echo "schema: not checked (no x-check in $NCL)" >&2
    exit 0
    ;;
esac
