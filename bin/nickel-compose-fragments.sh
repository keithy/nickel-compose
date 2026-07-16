#!/usr/bin/env bash
# nickel-compose-fragments.sh — discover compose fragments in a tree.
#
# Usage:
#   nickel-compose fragments [--root <dir>] [--out <file>]
#
# Args are forwarded to find-fragments.sh.

set -euo pipefail

find-fragments.sh "$@"
