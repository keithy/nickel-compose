#!/usr/bin/env bash
# nickel-compose-report.sh — query the merged record.
#
# Usage:
#   nickel-compose report <field> [<compose.ncl>]
#
# Reads ./compose.ncl from cwd by default; pass a path to query a
# different file. Does NOT re-render — run `use` separately when
# you want a fresh render.
#
# Fields available: services, ports (the composer.report.*
# namespace). The x-check, x-source fields on the merged record
# itself are also reachable but typically consumed by tooling
# reading the rendered YAML directly.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: nickel-compose report <field> [<compose.ncl>]" >&2
  exit 1
fi
field="$1"
ncl="${2:-./compose.ncl}"
if [[ ! -f "$ncl" ]]; then
  echo "no such file: $ncl (run 'use' first to render)" >&2
  exit 1
fi

# Delegate to nickel-compose-run. The `config` name is arbitrary
# — it just needs to match the expression. compose is pre-loaded
# by nickel-compose-run.
expr="compose.report.\"$field\" config"
nickel-compose-run.sh config="$ncl" -- "$expr"
