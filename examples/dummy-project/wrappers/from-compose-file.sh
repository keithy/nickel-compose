#!/usr/bin/env bash
# wrappers/from-compose-file.sh — render podman-compose.yml from $COMPOSE_FILE.
#
# Reads the colon-separated COMPOSE_FILE, generates a temporary
# config.ncl with literal imports for each fragment, runs nickel
# export, then cleans up the temp file.
#
# Usage:
#   COMPOSE_FILE="a.yml:b.yml:..." ./wrappers/from-compose-file.sh
#   COMPOSE_FILE="a.yml:b.yml:..." ./wrappers/from-compose-file.sh --out my.yml
#
# Why this exists:
#
#   Nickel 1.17 requires `import` paths to be literals at parse time.
#   This wrapper is the env-driven equivalent: you keep setting
#   COMPOSE_FILE the way you always have, and we handle the rest.
#
# To make this your default, set it as the mise cd hook:
#
#   [hooks]
#   cd = "QUIET=true $MISE_PROJECT_ROOT/wrappers/from-compose-file.sh"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# nickel-compose root is three levels up from this script:
# examples/dummy-project/wrappers/ -> examples/dummy-project/ -> examples/ -> <repo root>
NC_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# Paths in COMPOSE_FILE are resolved relative to cwd, like docker-compose.
CWD="$(pwd)"

OUT="podman-compose.yml"
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

: "${COMPOSE_FILE:=compose.yml:services/web.yml:services/db.yml:overlays/dev.yml}"

if [[ "$COMPOSE_FILE" == "compose.yml:services/web.yml:services/db.yml:overlays/dev.yml" ]] && [[ ! -f "compose.yml" ]]; then
  echo "COMPOSE_FILE not set and no default compose.yml in cwd" >&2
  echo "Set COMPOSE_FILE or run from a directory containing compose.yml" >&2
  exit 1
fi

# Split COMPOSE_FILE on `:` and emit one `import` per path.
# Paths in COMPOSE_FILE are relative to cwd, so we prefix with $ROOT
# to make them absolute (Nickel resolves imports from the importing
# file's directory, not cwd).
generate_config() {
  local compose_file="$1"
  echo "let build = import \"$NC_ROOT/lib/merge.ncl\" in"
  echo ""
  echo "let fragments = ["
  IFS=':' read -ra parts <<< "$compose_file"
  for path in "${parts[@]}"; do
    # If absolute, use as-is; otherwise prepend $CWD.
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

generate_config "$COMPOSE_FILE" > "$TMP"

$NICKEL export --format yaml "$TMP" | sed -n '2,$p' > "$OUT"

echo "rendered: $OUT"