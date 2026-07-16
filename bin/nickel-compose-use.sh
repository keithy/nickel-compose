#!/usr/bin/env bash
# nickel-compose-use.sh — render config.ncl to compose.{ncl,yaml}.
#
# Usage:
#   nickel-compose use [config.ncl] [--out <yaml>]
#
# The first non-flag positional is the config. If none is given,
# fall back to $NICKEL_COMPOSE if set, else ./config.ncl. Anything
# after the config (flags included) is forwarded to to-compose.sh.
# compose.ncl and compose.yaml land in cwd by default.

set -euo pipefail

config=""
while [[ $# -gt 0 && "$1" != --* ]]; do
  if [[ -n "$config" ]]; then
    echo "use: only one config path may be given" >&2
    exit 1
  fi
  config="$1"
  shift
done
if [[ -z "$config" ]]; then
  if [[ -n "${NICKEL_COMPOSE:-}" ]]; then
    config="$NICKEL_COMPOSE"
  else
    config="./config.ncl"
  fi
fi

to-compose.sh --in "$config" "$@"
