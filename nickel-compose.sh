#!/usr/bin/env bash
# nickel-compose.sh — single entry point for all nickel-compose operations.
#
# Convention: `nickel-compose.sh <verb> <args>`. The verb is a
# single keyword. Common verbs:
#
#   use <config.ncl>                  # render config to compose.yaml
#                                     # (and compose.ncl in the same dir)
#   check [config.ncl]                # strict typecheck
#   from [NICKEL_COMPOSE=...]          # generate config.ncl from $NICKEL_COMPOSE
#   fragments <dir>                   # discover compose fragments
#   report <field> <config.ncl>       # query the merged record
#   schema <contract>                 # show a contract's fields
#   help                              # this message
#
# `use` is the default verb. If you run nickel-compose.sh with
# no args, it prints this help. If you run with one arg that
# ends in `.ncl`, it's treated as `use <arg>`. Otherwise you
# must specify the verb explicitly.
#
# Backed by the scripts in scripts/. The scripts/ directory
# is the implementation; this file is the dispatcher.
#
# Install: symlink or copy into PATH as `nickel-compose` or
# `nickel-compose.sh`.

set -euo pipefail

# The script lives at <repo>/nickel-compose.sh. Scripts are
# at <repo>/scripts/. The engine is at <repo>/nickel-compose.ncl.
# Resolve the symlink so paths work whether invoked via the
# symlink or directly.
SCRIPT_PATH="$(readlink -f "$0")"
NC_ROOT="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
TO_COMPOSE="$NC_ROOT/scripts/to-compose.sh"
CHECK_SH="$NC_ROOT/scripts/check.sh"
FROM_WRAPPER="$NC_ROOT/scripts/from-nickel-compose.sh"
FIND_FRAGMENTS="$NC_ROOT/scripts/find-fragments.sh"
ENGINE="$NC_ROOT/nickel-compose.ncl"

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
  exit 0
}

# --- verbs ---

verb_use() {
  # `use <config.ncl> [<args>]` — render. The config file is the
  # first positional arg; anything else is forwarded to
  # to-compose.sh (e.g. `--out <yaml>`, `--engine <path>`).
  if [[ $# -eq 0 ]]; then
    echo "usage: nickel-compose.sh use <config.ncl> [--out <yaml>] [--engine <path>]" >&2
    exit 1
  fi
  local config="$1"
  shift
  "$TO_COMPOSE" --in "$config" "$@"
}

verb_check() {
  # `check [config.ncl]` — typecheck. No arg = engine only.
  if [[ $# -eq 0 ]]; then
    "$CHECK_SH"
  else
    "$CHECK_SH" "$@"
  fi
}

verb_from() {
  # `from` — generate config.ncl from $NICKEL_COMPOSE.
  "$FROM_WRAPPER" "$@"
}

verb_fragments() {
  # `fragments [--root <dir>] [--out <file>]` — discover
  # compose fragments in a tree. Args are forwarded to
  # find-fragments.sh.
  "$FIND_FRAGMENTS" "$@"
}

verb_report() {
  # `report <field> <config.ncl>` — query the merged record.
  # field is one of the composer.report.* names (services,
  # ports, ...). The config is rendered first to produce
  # compose.ncl; then we eval a tiny helper that imports
  # the engine and the rendered .ncl, calls the report
  # function with the merged record, and prints the result.
  #
  # The helper is written next to compose.ncl because Nickel's
  # import path is relative to the importing file, not cwd.
  if [[ $# -lt 2 ]]; then
    echo "usage: nickel-compose.sh report <field> <config.ncl>" >&2
    exit 1
  fi
  local field="$1"
  local config="$2"
  # Render first (idempotent if compose.ncl/compose.yaml exist).
  "$TO_COMPOSE" --in "$config" >/dev/null
  local config_dir
  config_dir="$(cd "$(dirname "$config")" && pwd)"
  local helper="$config_dir/.report-query.ncl"
  cat > "$helper" <<EOF
let composer = import "$NC_ROOT/nickel-compose.ncl" in
composer.report."$field" (import "./compose.ncl")
EOF
  (
    cd "$config_dir"
    nickel eval "$helper"
  )
  rm -f "$helper"
}

verb_schema() {
  # `schema <Contract>` — show a contract's fields and their
  # doc strings. Uses `nickel query` against the engine
  # source. The contract is at the top level of the public
  # record (Service, Port, Volume, Network, Fragment).
  #
  # If a second arg is given, it's a sub-field path and we
  # print just that field's metadata.
  if [[ $# -eq 0 ]]; then
    echo "usage: nickel-compose.sh schema <Contract> [field]" >&2
    exit 1
  fi
  local contract="$1"
  local field="${2:-}"
  if [[ ! -f "$ENGINE" ]]; then
    echo "engine not found: $ENGINE" >&2
    exit 1
  fi
  # Strip ANSI color codes from nickel query output. Some
  # shells support $'...' but POSIX sh doesn't; use printf
  # to build the escape sequence.
  local esc
  esc="$(printf '\033')"
  local strip_ansi="sed -e \"s/${esc}\\[[0-9;]*m//g\""
  if [[ -n "$field" ]]; then
    # Specific field: show its doc
    nickel query --field "${contract}.${field}" --doc "$ENGINE" 2>/dev/null \
      | eval "$strip_ansi" \
      | sed -n 's/^[[:space:]]*•[[:space:]]*documentation[[:space:]]*:[[:space:]]*//p'
  else
    # Whole contract: list fields, then show each doc
    local fields
    fields="$(nickel query --field "$contract" "$ENGINE" 2>/dev/null \
      | eval "$strip_ansi" \
      | grep -E '^[[:space:]]*•' \
      | sed 's/^[[:space:]]*•[[:space:]]*//')"
    if [[ -z "$fields" ]]; then
      echo "Contract $contract not found in $ENGINE" >&2
      exit 1
    fi
    echo "Contract: $contract"
    echo "Fields:"
    for f in $fields; do
      echo "  $f"
    done
    echo ""
    echo "Documentation:"
    for f in $fields; do
      local doc
      doc="$(nickel query --field "${contract}.${f}" --doc "$ENGINE" 2>/dev/null \
        | eval "$strip_ansi" \
        | sed -n 's/^[[:space:]]*•[[:space:]]*documentation[[:space:]]*:[[:space:]]*//p')"
      if [[ -n "$doc" ]]; then
        printf "  %-15s %s\n" "$f" "$doc"
      fi
    done
  fi
}

# --- dispatch ---

if [[ $# -eq 0 ]]; then
  usage
fi

verb="$1"
shift

case "$verb" in
  use)        verb_use "$@" ;;
  check)      verb_check "$@" ;;
  from)       verb_from "$@" ;;
  fragments)  verb_fragments "$@" ;;
  report)     verb_report "$@" ;;
  schema)     verb_schema "$@" ;;
  help|--help|-h) usage ;;
  *)
    # Be lenient: if the first arg ends in .ncl, treat as `use`.
    if [[ "$verb" == *.ncl ]]; then
      verb_use "$verb" "$@"
    else
      echo "unknown verb: $verb" >&2
      echo "run 'nickel-compose.sh help' for usage" >&2
      exit 1
    fi
    ;;
esac
