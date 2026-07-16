#!/usr/bin/env bash
# nickel-compose-help.sh — print the verb list.
#
# Called as `nickel-compose help` (via the dispatcher) or directly.
# All nickel-compose-* tools must be on PATH.

cat <<EOF
nickel-compose — fragment-driven compose deployment

Convention: \`nickel-compose <verb> <args>\`. Verbs live alongside
this script as nickel-compose-<verb>.sh and are dispatched by name.

Verbs:
  use [config.ncl] [--out <yaml>]    # render config to compose.{ncl,yaml}
                                    # config.ncl defaults to \$NICKEL_COMPOSE
                                    # else ./config.ncl
  check [config.ncl]                # strict typecheck
  fragments [--root <dir>] [--out <file>]
                                    # discover compose fragments
  report <field> [<compose.ncl>]    # query the merged record
                                    # (re-render with \`use\` first)
  schema <Contract> [field]         # show a contract's fields
  help                              # this message

Defaults:
  \`use\` writes compose.ncl and compose.yaml to cwd. These are
  build artifacts and should be gitignored. Pass --out to write
  elsewhere.
  \`report\` reads ./compose.ncl from cwd by default (no
  re-render). Pass a path to query a different file.

NICKEL_COMPOSE:
  Pointed at a config.ncl by mise/env/CD-hook so that bare
  \`nickel-compose use\` resolves to that file.
  An explicit \`use config.ncl\` always wins over \$NICKEL_COMPOSE.
  \`dc2nc.sh --pick\` is the recommended way to generate the
  config.ncl that NICKEL_COMPOSE points at.
EOF
