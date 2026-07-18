#!/usr/bin/env bash
# scripts/dc2nc.sh — pick compose fragments and emit a bare-list config.ncl.
#
# Reads a list of fragment paths on stdin (one per line) and writes a
# Nickel file on stdout. The output lists ALL discovered candidates as
# commented imports, with the --picked subset uncommented and live:
#
#   # dc2nc.sh output — bare-list config.ncl
#   # Uncomment a line to enable a fragment. The picked subset is live.
#   [
#     import "./base.yml",
#     import "./services/web.yml",
#     # import "./services/db.yml",
#     # import "./overlays/dev.yml",
#   ]
#
# Usage:
#   find . -name '*.yml' | dc2nc.sh --pick base.yml > config.ncl
#   find . \( -name '*.yml' -o -name '*.ncl' \) \
#     | dc2nc.sh --pick base.yml --pick services/web.yml > config.ncl
#   dc2nc.sh --find-all --pick base.yml > config.ncl
#   dc2nc.sh --find-all base.yml services/web.yml > config.ncl
#
# Options:
#   --pick PATH     include fragments whose path equals PATH (repeatable).
#                   Bare positional args are treated the same as --pick PATH.
#   --find-all      run `find . \( -name '*.yml' -o -name '*.ncl' \)`
#                   instead of reading from stdin
#   -h, --help      show this help
#
# The caller is expected to be cd'd into the project root.

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
script_name="$(basename "$0")"

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
  exit 0
}

# --- parse args ---
#
# Picks may be given as repeated `--pick PATH` flags OR as bare
# positional args. The two forms are equivalent; mixing is allowed.
# This lets callers write either:
#   dc2nc.sh --pick base.yml --pick services/web.yml
#   dc2nc.sh base.yml services/web.yml
#   dc2nc.sh --find-all base.yml services/web.yml

picks=()
find_all=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pick)
      [[ $# -ge 2 ]] || { echo "$script_name: --pick requires a value" >&2; exit 1; }
      picks+=("$2")
      shift 2
      ;;
    --find-all)
      find_all=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    --*)
      echo "$script_name: unknown arg: $1" >&2
      exit 1
      ;;
    *)
      picks+=("$1")
      shift
      ;;
  esac
done

if [[ ${#picks[@]} -eq 0 ]]; then
  echo "$script_name: at least one fragment path is required" >&2
  echo "  e.g. $script_name --find-all --pick base.yml" >&2
  echo "  run '$script_name --help' for usage" >&2
  exit 1
fi

# --- collect candidates ---
#
# Discovery sources, in order of preference:
#   1. --find-all: run `find . \( -name '*.yml' -o -name '*.ncl' \)` itself
#   2. stdin: read paths (one per line), ignoring blanks
#   3. fallback: if stdin is empty AND --find-all is unset, run `find` too.
#      This lets `dc2nc.sh --pick base.yml` (no pipe) work — same
#      behaviour as `--find-all --pick base.yml`.

if [[ $find_all -eq 1 ]]; then
  candidates="$(find . \( -name '*.yml' -o -name '*.ncl' \) -not -path './out/*' \
    | sed 's|^\./||')"
else
  if [[ -t 0 ]]; then
    echo "$script_name: reading candidate paths from stdin (Ctrl-D to finish, or use --find-all)" >&2
  fi
  candidates="$(cat \
    | sed 's|^\./||' \
    | sed '/^$/d')"
  if [[ -z "$candidates" ]]; then
    # Empty stdin — fall back to discovery so the picker still works
    # for the common `dc2nc.sh --pick foo.yml` case.
    candidates="$(find . \( -name '*.yml' -o -name '*.ncl' \) -not -path './out/*' \
      | sed 's|^\./||')"
  fi
fi

# Preserve input order (meaningful to the user — the order they
# listed fragments is the order they're applied) but de-dupe so
# the same path doesn't appear twice in the output list.
candidates="$(awk '!seen[$0]++' <<< "$candidates")"

# --- emit bare-list config.ncl on stdout ---

printf '# dc2nc.sh output — bare-list config.ncl\n'
printf '# Uncomment a line to enable a fragment. The picked subset is live.\n'
printf '[\n'
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  picked=0
  for p in "${picks[@]}"; do
    if [[ "$path" == "$p" ]]; then
      picked=1
      break
    fi
  done
  if [[ $picked -eq 1 ]]; then
    printf '  import "./%s",\n' "$path"
  else
    printf '  # import "./%s",\n' "$path"
  fi
done <<< "$candidates"
printf ']\n'
