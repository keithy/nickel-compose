#!/usr/bin/env bash
# nickel-compose-schema.sh — show a contract's fields and doc strings.
#
# Usage:
#   nickel-compose schema <Contract> [field]
#
# Uses `nickel query` against the engine source. The contract is
# at the top level of the public record (Service, Port, Volume,
# Network, Fragment).

set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "usage: nickel-compose schema <Contract> [field]" >&2
  exit 1
fi
contract="$1"
field="${2:-}"

# Locate the engine. Same search order as check.sh and
# nickel-compose-run.sh.
ENGINE="${NICKEL_COMPOSE_ENGINE:-}"
if [[ -z "$ENGINE" ]]; then
  for candidate in \
      "./nickel-compose.ncl" \
      "${NICKEL_COMPOSE_ROOT:-}/nickel-compose.ncl"; do
    if [[ -f "$candidate" ]]; then
      ENGINE="$candidate"
      break
    fi
  done
fi
if [[ ! -f "$ENGINE" ]]; then
  echo "engine not found" >&2
  echo "set NICKEL_COMPOSE_ENGINE to override" >&2
  exit 1
fi

# Strip ANSI color codes from nickel query output.
esc="$(printf '\033')"
strip_ansi="sed -e \"s/${esc}\\[[0-9;]*m//g\""

if [[ -n "$field" ]]; then
  nickel query --field "${contract}.${field}" --doc "$ENGINE" 2>/dev/null \
    | eval "$strip_ansi" \
    | sed -n 's/^[[:space:]]*•[[:space:]]*documentation[[:space:]]*:[[:space:]]*//p'
else
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
    doc="$(nickel query --field "${contract}.${f}" --doc "$ENGINE" 2>/dev/null \
      | eval "$strip_ansi" \
      | sed -n 's/^[[:space:]]*•[[:space:]]*documentation[[:space:]]*:[[:space:]]*//p')"
    if [[ -n "$doc" ]]; then
      printf "  %-15s %s\n" "$f" "$doc"
    fi
  done
fi
