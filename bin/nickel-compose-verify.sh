#!/usr/bin/env bash
# bin/nickel-compose-verify.sh — print x-check from a rendered compose.ncl.
#
# `nickel-compose-run composed=${1:-compose.ncl} -- composed.x-check`.
# Exits 0 if ok=true, 1 if not, 2 if missing or no x-check field.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NCR="$SCRIPT_DIR/nickel-compose-run.sh"
[[ -x "$NCR" ]] || NCR="nickel-compose-run.sh"

ncl="${1:-./compose.ncl}"
[[ -f "$ncl" ]] || { echo "no such file: $ncl" >&2; exit 2; }

record="$("$NCR" "composed=$ncl" -- "composed.x-check" 2>/dev/null)" \
  || { echo "no x-check field in $ncl" >&2; exit 2; }

echo "$record"
echo "$record" | grep -q "ok = true"