#!/usr/bin/env bash
# wrappers/from-compose-file.sh — render compose.yml from $COMPOSE_FILE.
#
# Reads the comma/colon/semicolon-separated COMPOSE_FILE (set by your
# shell, .env, .bashrc, or mise [env]) and renders a single compose.yml
# by merging those fragments with Compose semantics.
#
# Usage:
#   COMPOSE_FILE="a.yml:b.yml:..." ./wrappers/from-compose-file.sh
#   ./wrappers/from-compose-file.sh --out my.yml
#
# Why this exists:
#
#   Nickel 1.17 requires `import` paths to be literals at parse time.
#   This wrapper reads COMPOSE_FILE at run time and emits a temp
#   config.ncl with literal imports, so you keep your existing
#   COMPOSE_FILE workflow without editing Nickel files.
#
# COMPOSE_FILE handling:
#
#   The wrapper reads COMPOSE_FILE into a local variable and never
#   modifies or exports the env var. Subprocesses (nickel, podman)
#   see the env as-is. Treat COMPOSE_FILE as input to the wrapper,
#   not as configuration that survives the call.
#
# Delimiter:
#
#   COMPOSE_FILE uses `:` as the fragment separator (the docker-compose
#   convention). Other delimiters like `,` or `;` are not supported
#   because they conflict with .env file parsing (`,` may be stripped)
#   or shell syntax (`;` starts a comment).
#
#   Single-file COMPOSE_FILE values (no `:`) are treated as a
#   one-element list.
#
# Output filename:
#
#   compose.yml by default — auto-picked by both `podman-compose`
#   and `docker compose`. Override with --out.
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

# Read COMPOSE_FILE into a local var. The env var itself is untouched
# so subprocesses see whatever the caller exported.
compose_file="${COMPOSE_FILE:-compose.yml:services/web.yml:services/db.yml:overlays/dev.yml}"

if [[ "$compose_file" == "compose.yml:services/web.yml:services/db.yml:overlays/dev.yml" ]] && [[ ! -f "compose.yml" ]]; then
  echo "COMPOSE_FILE not set and no default compose.yml in cwd" >&2
  echo "Set COMPOSE_FILE or run from a directory containing compose.yml" >&2
  exit 1
fi

# Split COMPOSE_FILE on `:` (docker convention), `,`, or `;` and
# emit one `import` per path. Paths are resolved relative to cwd;
# we prefix them to absolute since Nickel resolves imports from
# the importing file's directory, not cwd.
generate_config() {
  local cf="$1"
  echo "let build = import \"$NC_ROOT/lib/merge.ncl\" in"
  echo ""
  echo "let fragments = ["

  # Split on `:` (the docker-compose convention for COMPOSE_FILE lists).
  # Single-file COMPOSE_FILE values (no `:`) are treated as a
  # one-element list.
  if [[ "$cf" == *:* ]]; then
    # shellcheck disable=SC2162
    IFS=':' read -ra parts <<< "$cf"
    for path in "${parts[@]}"; do
      [[ -n "$path" ]] && emit_fragment "$path"
    done
  else
    emit_fragment "$cf"
  fi

  echo "] in"
  echo ""
  echo "build fragments"
}

emit_fragment() {
  local path="$1"
  local abs
  case "$path" in
    /*) abs="$path" ;;
    *)  abs="$CWD/$path" ;;
  esac
  echo "  import \"$abs\","
}

if command -v mise >/dev/null 2>&1; then
  NICKEL="mise exec -- nickel"
else
  NICKEL="nickel"
fi

TMP="$(mktemp -t nickel-compose.XXXXXX.ncl)"
trap 'rm -f "$TMP"' EXIT

generate_config "$compose_file" > "$TMP"

$NICKEL export --format yaml "$TMP" | sed -n '2,$p' > "$OUT"

echo "rendered: $OUT"