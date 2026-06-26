#!/usr/bin/env bash
# wrappers/from-compose-file.sh — render compose.yml from $COMPOSE_FRAGMENTS.
#
# Reads the colon-separated COMPOSE_FRAGMENTS (set by your shell,
# .env, .bashrc, or mise [env]) and renders a single compose.yml by
# merging those fragments with Compose semantics.
#
# Usage:
#   COMPOSE_FRAGMENTS="a.yml:b.yml:..." ./wrappers/from-compose-file.sh
#   ./wrappers/from-compose-file.sh --out my.yml
#
# Why COMPOSE_FRAGMENTS instead of COMPOSE_FILE:
#
#   COMPOSE_FILE is reserved by compose tools for the merged output
#   file path. After rendering, the user (or a tool) typically sets
#   COMPOSE_FILE=compose.yml. If nickel-compose also used COMPOSE_FILE
#   as input, the two would collide — and any env_file: .env in the
#   output would recursively read the input list as the file path.
#
#   COMPOSE_FRAGMENTS is the input list. compose.yml is the output.
#   Two distinct variables, two distinct roles.
#
# Why this exists:
#
#   Nickel 1.17 requires `import` paths to be literals at parse time.
#   This wrapper reads COMPOSE_FRAGMENTS at run time and emits a temp
#   config.ncl with literal imports, so you keep your existing
#   fragment-list workflow without editing Nickel files.
#
# COMPOSE_FRAGMENTS handling:
#
#   The wrapper reads COMPOSE_FRAGMENTS into a local variable and
#   never modifies or exports the env var. Subprocesses (nickel,
#   podman) see the env as-is. Treat COMPOSE_FRAGMENTS as input to
#   the wrapper, not as configuration that survives the call.
#
# Delimiter:
#
#   COMPOSE_FRAGMENTS uses `:` as the fragment separator (the
#   docker-compose convention). Other delimiters like `,` or `;`
#   are not supported because they conflict with .env file parsing
#   (`,` may be stripped) or shell syntax (`;` starts a comment).
#
#   Single-file COMPOSE_FRAGMENTS values (no `:`) are treated as a
#   one-element list.
#
# Output filename:
#
#   compose.yml by default — auto-picked by both `podman-compose`
#   and `docker compose`. Override with --out.
#
#   The wrapper refuses to write into a path that's also in the
#   fragment list (would clobber a source file). If you have a
#   source fragment named compose.yml, pass --out to write
#   elsewhere (e.g. --out merged-compose.yml) and use
#   `podman-compose -f merged-compose.yml up`.
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
# Paths in COMPOSE_FRAGMENTS are resolved relative to cwd, like docker-compose.
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

# Read COMPOSE_FRAGMENTS into a local var. The env var itself is
# untouched so subprocesses see whatever the caller exported.
compose_fragments="${COMPOSE_FRAGMENTS:-base.yml:services/web.yml:services/db.yml:overlays/dev.yml}"

if [[ "$compose_fragments" == "base.yml:services/web.yml:services/db.yml:overlays/dev.yml" ]] && [[ ! -f "base.yml" ]]; then
  echo "COMPOSE_FRAGMENTS not set and no default base.yml in cwd" >&2
  echo "Set COMPOSE_FRAGMENTS or run from a directory containing base.yml" >&2
  exit 1
fi

# Check for collision: refuse to write into a path that's also in the
# fragment list. Otherwise we'd clobber a source file mid-render.
abs_out="$OUT"
[[ "$abs_out" != /* ]] && abs_out="$CWD/$abs_out"
IFS=':' read -ra fragment_paths <<< "$compose_fragments"
for path in "${fragment_paths[@]}"; do
  resolved="$path"
  [[ "$resolved" != /* ]] && resolved="$CWD/$resolved"
  if [[ "$resolved" == "$abs_out" ]]; then
    echo "output path '$OUT' is also in COMPOSE_FRAGMENTS — would clobber source" >&2
    echo "use --out to write to a different path, e.g. --out merged-compose.yml" >&2
    exit 1
  fi
done

# Split COMPOSE_FRAGMENTS on `:` and emit one `import` per path.
# Paths are resolved relative to cwd; we prefix them to absolute
# since Nickel resolves imports from the importing file's directory,
# not cwd.
generate_config() {
  local cf="$1"
  echo "let build = import \"$NC_ROOT/lib/merge.ncl\" in"
  echo ""
  echo "let fragments = ["

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

generate_config "$compose_fragments" > "$TMP"

$NICKEL export --format yaml "$TMP" | sed -n '2,$p' > "$OUT"

echo "rendered: $OUT"