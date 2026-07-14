#!/usr/bin/env bash
# scripts/find-fragments.sh — discover compose fragments, emit a .ncl template.
#
# Scans a project tree for candidate compose fragments and emits a
# Nickel file with every candidate as a commented-out `import` line.
# Uncomment what you want; the result is a working config.ncl.
#
# Conventions for what counts as a candidate:
#   - root-level compose.yml
#   - docker-compose*.yml anywhere
#   - service.*.yml and service.*.ncl (per-service fragments)
#   - +*.yml and +*.ncl (overlays)
#   - ~*.yml and ~*.ncl (post-overlays / resets)
#
# Paths in the emitted file are relative to:
#   - cwd, if no --out is given (stdout mode)
#   - the directory of --out, if --out is given
#
# The scan root defaults to cwd; pass --root to override.
#
# Usage:
#   ./scripts/find-fragments.sh                          # emit to stdout
#   ./scripts/find-fragments.sh --out config/found.ncl  # write to file
#   ./scripts/find-fragments.sh --root /path/to/project # scan a different root
#
# Skip patterns (always):
#   .git/  node_modules/  tests/  examples/  RELEASES/  build*/
#   *.bak  *.example  The output file itself (if --out is given).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NC_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

OUT=""
ROOT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      OUT="$2"
      shift 2
      ;;
    --root)
      ROOT="$2"
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

# Resolve the directory that emitted paths should be relative to.
#   - stdout mode: ROOT (the scan root) — paths in the output point
#     at fragments from the project root.
#   - file mode (--out given): the directory of --out — paths in the
#     output point at fragments from the output file's location, so
#     imports resolve correctly when the .ncl is moved.
if [[ -n "$OUT" ]]; then
  if [[ "$OUT" != /* ]]; then
    OUT_DIR="$(cd "$(dirname "$OUT")" && pwd)"
  else
    OUT_DIR="$(dirname "$OUT")"
  fi
  OUT_BASE="$(basename "$OUT")"
else
  OUT_BASE="found.ncl"
  OUT_DIR=""
  # Will be set to ROOT after ROOT is resolved below.
fi

# Resolve root. Default: cwd. Override with --root.
if [[ -z "$ROOT" ]]; then
  ROOT="$(pwd)"
fi
if [[ "$ROOT" != /* ]]; then
  ROOT="$(cd "$ROOT" && pwd)"
fi

# In stdout mode, OUT_DIR defaults to ROOT.
if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="$ROOT"
fi

# Locate the nickel-compose merge engine. Search order:
#   1. $ROOT/nickel-compose/lib/nickel-compose.ncl  (submodule layout)
#   2. $ROOT/lib/nickel-compose.ncl                 (vendored layout)
#   3. $SCRIPT_DIR/../lib/nickel-compose.ncl        (alongside the script,
#                                          when scanning a nickel-
#                                          compose checkout itself)
# Compute the import path from OUT_DIR so it's correct wherever
# the output lands.
MERGE_LIB=""
for candidate in \
    "$ROOT/nickel-compose/lib/nickel-compose.ncl" \
    "$ROOT/lib/nickel-compose.ncl" \
    "$NC_ROOT/lib/nickel-compose.ncl"; do
  if [[ -f "$candidate" ]]; then
    MERGE_LIB="$(realpath --relative-to="$OUT_DIR" "$candidate" 2>/dev/null || echo "$candidate")"
    if [[ "$MERGE_LIB" == /* ]]; then
      MERGE_LIB="$candidate"
    fi
    MERGE_LIB="${MERGE_LIB#./}"
    break
  fi
done
if [[ -z "$MERGE_LIB" ]]; then
  # Last resort: assume a submodule at the project root and emit a
  # best-guess import path. The user can edit before rendering.
  if [[ "$OUT_DIR" == "$ROOT" ]]; then
    MERGE_LIB="nickel-compose/lib/nickel-compose.ncl"
  else
    MERGE_LIB="../nickel-compose/lib/nickel-compose.ncl"
  fi
fi

# Build find -prune expressions. Two flavors of skip:
#   1. -path "$ROOT/<dir>" matches the dir at ROOT level (e.g. tests/
#      at the project root, not the spec's tests/ subdir under out/).
#   2. -name "<dir>" -type d -prune matches a dir of that name at any
#      depth within ROOT.
SKIP_DIRS=( ".git" "node_modules" "tests" "examples" "RELEASES" "build" )
PRUNE_EXPR=""
for d in "${SKIP_DIRS[@]}"; do
  PRUNE_EXPR+=" -path \"$ROOT/$d\" -prune -o"
  PRUNE_EXPR+=" -name \"$d\" -type d -prune -o"
done
# Catch build-next, build-current, etc. (any dir starting with build-).
PRUNE_EXPR+=" -name \"build-*\" -type d -prune -o"

mapfile -t CANDIDATES < <(
  eval "find \"$ROOT\" $PRUNE_EXPR -type f \\( -name \"compose.yml\" -o -name \"compose.ncl\" -o -name \"docker-compose*.yml\" -o -name \"docker-compose*.ncl\" -o -name \"service.*.yml\" -o -name \"service.*.ncl\" -o -path \"*/services/*.yml\" -o -path \"*/services/*.ncl\" -o -name \"+*.yml\" -o -name \"+*.ncl\" -o -name \"~*.yml\" -o -name \"~*.ncl\" -o -path \"*/overlays/*.yml\" -o -path \"*/overlays/*.ncl\" \\) -print" 2>/dev/null | sort
)

# Filter out the output file itself.
if [[ -n "$OUT" ]]; then
  abs_out="$OUT_DIR/$OUT_BASE"
  FILTERED=()
  for c in "${CANDIDATES[@]}"; do
    [[ "$c" != "$abs_out" ]] && FILTERED+=("$c")
  done
  CANDIDATES=("${FILTERED[@]}")
fi

# Filter out .bak and .example files.
FILTERED=()
for c in "${CANDIDATES[@]}"; do
  base="$(basename "$c")"
  case "$base" in
    *.bak|*.example) ;;
    # Skip this script's own outputs and other config files that
    # share a name with a fragment pattern. These are configs, not
    # fragments — including them in the output would create a
    # self-import cycle on a subsequent run.
    compose.ncl|config.ncl|found.ncl|config*.ncl) ;;
    *) FILTERED+=("$c") ;;
  esac
done
CANDIDATES=("${FILTERED[@]}")

# Group candidates by top-level subdirectory relative to ROOT.
declare -A SECTION_SEEN
ORDER=()
declare -A SECTION_FILES
i=0
for c in "${CANDIDATES[@]}"; do
  rel="${c#$ROOT/}"
  if [[ "$rel" == "$c" || "$rel" != */* ]]; then
    section="root"
  else
    section="${rel%%/*}"
  fi
  if [[ -z "${SECTION_SEEN[$section]+x}" ]]; then
    SECTION_SEEN[$section]=$i
    ORDER+=("$section")
    i=$((i + 1))
  fi
  SECTION_FILES[$section]+="$c"$'\n'
done

# Emit the template to a temp file, then route to stdout or file.
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

{
  echo "# $OUT_BASE -- generated by find-fragments.sh"
  echo "# Scan root: $ROOT"
  echo "# Paths below are relative to: $OUT_DIR"
  echo "# Merge engine: $MERGE_LIB"
  echo "# Render: nickel export --format yaml $OUT_BASE > compose.yaml"
  echo "#"
  echo "# All candidates below are commented out. Uncomment the"
  echo "# imports you want to include. Order matters: later wins"
  echo "# on key collision."
  echo ""
  echo "let nc = import \"$MERGE_LIB\" in"
  echo ""
  echo "let fragments = ["

  for section in "${ORDER[@]}"; do
    if [[ "$section" == "root" ]]; then
      echo "# === root ==="
    else
      echo "# === $section ==="
    fi
    while IFS= read -r path; do
      [[ -z "$path" ]] && continue
      rel="$(realpath --relative-to="$OUT_DIR" "$path" 2>/dev/null || echo "$path")"
      if [[ "$rel" == /* ]]; then
        rel="$path"
      fi
      rel="${rel#./}"
      echo "# import \"$rel\","
    done <<< "${SECTION_FILES[$section]}"
    echo ""
  done
  echo "] in"
  echo ""
  echo "nc.merge fragments"
} > "$TMP"

if [[ -n "$OUT" ]]; then
  mkdir -p "$OUT_DIR"
  mv "$TMP" "$OUT_DIR/$OUT_BASE"
  trap - EXIT
  echo "wrote: $OUT_DIR/$OUT_BASE (${#CANDIDATES[@]} candidates, scan root: $ROOT)" >&2
else
  cat "$TMP"
  trap - EXIT
fi