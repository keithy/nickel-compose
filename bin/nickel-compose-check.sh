#!/usr/bin/env bash
# nickel-compose-check.sh — strict typecheck of engine and optional config.
#
# Usage:
#   nickel-compose check [config.ncl]
#
# No arg = engine only. Args are forwarded to check.sh.

set -euo pipefail

check.sh "$@"
