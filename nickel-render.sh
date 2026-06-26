#!/usr/bin/env bash
# nickel-render.sh — render a nickel-compose config to podman-compose.yml.
#
# Usage:
#   nickel-render.sh --config PATH [--out PATH]
#
# Defaults:
#   --config: ./config.ncl
#   --out:    ./podman-compose.yml
#
# Requires nickel (mise: aqua:nickel-lang/nickel) on PATH or via mise exec.

set -euo pipefail

SCRIPT="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT")" && pwd)"

CONFIG="config.ncl"
OUT="podman-compose.yml"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG="$2"
      shift 2
      ;;
    --out)
      OUT="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,/^$/p' "$SCRIPT" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "$CONFIG" ]]; then
  echo "config not found: $CONFIG" >&2
  exit 1
fi

# Run nickel via mise exec if available, else direct.
if command -v mise >/dev/null 2>&1; then
  NICKEL="mise exec -- nickel"
else
  NICKEL="nickel"
fi

if ! command -v ${NICKEL%% *} >/dev/null 2>&1 && ! mise exec -- true >/dev/null 2>&1; then
  echo "nickel not found on PATH and mise exec failed" >&2
  exit 1
fi

# Typecheck first.
$NICKEL typecheck "$CONFIG"

# Export to YAML.
$NICKEL export --format yaml "$CONFIG" > "$OUT"

echo "rendered: $OUT"