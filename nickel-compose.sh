#!/usr/bin/env bash
# nickel-compose.sh — single entry point for all nickel-compose operations.
#
# Convention: `nickel-compose.sh <verb> <args>`. The verb is a
# single keyword. Common verbs:
#
#   use <config.ncl> [--out <yaml>]    # render config to compose.{ncl,yaml}
#   check [config.ncl]                # strict typecheck
#   from                              # generate config.ncl from $NICKEL_COMPOSE
#   fragments [--root <dir>] [--out <file>]
#                                     # discover compose fragments
#   report <field> [<compose.ncl>]    # query the merged record
#                                     # (re-render with `use` first)
#   schema <Contract> [field]         # show a contract's fields
#   help                              # this message
#
# Defaults:
#   `use` writes compose.ncl and compose.yaml to the current
#   working directory. These are build artifacts and should
#   be gitignored. Pass --out to write elsewhere.
#   `report` reads ./compose.ncl from cwd by default (no
#   re-render). Pass a path to query a different file.
#   If you run with one arg that ends in `.ncl`, it's
#   treated as `use <arg>`.
#
# Backed by the scripts in scripts/. The scripts/ directory
# is the implementation; this file is the dispatcher.
#
# Install: symlink or copy into PATH as `nickel-compose` or
# `nickel-compose.sh`.

set -euo pipefail

# The script lives at <repo>/nickel-compose.sh. Resolve the
# symlink so paths work whether invoked via the symlink or
# directly.
SCRIPT_PATH="$(readlink -f "$0")"
NC_ROOT="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
TO_COMPOSE="$NC_ROOT/scripts/to-compose.sh"
CHECK_SH="$NC_ROOT/scripts/check.sh"
FROM_WRAPPER="$NC_ROOT/scripts/from-nickel-compose.sh"
FIND_FRAGMENTS="$NC_ROOT/scripts/find-fragments.sh"
NC_RUN="$NC_ROOT/scripts/nickel-compose-run.sh"
ENGINE="$NC_ROOT/nickel-compose.ncl"

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
  exit 0
}

# --- verbs ---

verb_use() {
  # `use <config.ncl> [--out <yaml>] [--engine <path>]` —
  # render. The config is the first positional arg; anything
  # else is forwarded to to-compose.sh. compose.ncl and
  # compose.yaml land in cwd by default (the user is
  # expected to gitignore them).
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
  # `report <field> [<compose.ncl>]` — query the merged
  # record. Reads ./compose.ncl from cwd by default; pass
  # a path to query a different file. Does NOT re-render
  # — the user runs `use` separately when they want a
  # fresh render.
  #
  # Special field `source` returns the path of the config
  # that produced the merged record (read from x-source on
  # compose.ncl, set by the engine when called via
  # merge_with_check / merge_with_source).
  if [[ $# -lt 1 ]]; then
    echo "usage: nickel-compose.sh report <field> [<compose.ncl>]" >&2
    exit 1
  fi
  local field="$1"
  local ncl="${2:-./compose.ncl}"
  if [[ ! -f "$ncl" ]]; then
    echo "no such file: $ncl (run 'use' first to render)" >&2
    exit 1
  fi
  # Delegate to nickel-compose-run. The `config` name is
  # arbitrary — it just needs to match the expression.
  # compose is pre-loaded by nickel-compose-run.
  local expr
  if [[ "$field" == "source" ]]; then
    expr='config."x-source"'
  else
    expr="compose.report.\"$field\" config"
  fi
  "$NC_RUN" config="$ncl" -- "$expr"
}

verb_schema() {
  # `schema <Contract> [field]` — show a contract's fields
  # and their doc strings. Uses `nickel query` against the
  # engine source. The contract is at the top level of the
  # public record (Service, Port, Volume, Network,
  # Fragment).
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
  # Strip ANSI color codes from nickel query output.
  local esc
  esc="$(printf '\033')"
  local strip_ansi="sed -e \"s/${esc}\\[[0-9;]*m//g\""
  if [[ -n "$field" ]]; then
    nickel query --field "${contract}.${field}" --doc "$ENGINE" 2>/dev/null \
      | eval "$strip_ansi" \
      | sed -n 's/^[[:space:]]*•[[:space:]]*documentation[[:space:]]*:[[:space:]]*//p'
  else
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
