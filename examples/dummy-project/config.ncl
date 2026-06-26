# config.ncl — first-time user entry point.
#
# This file lists the compose fragments to merge, in order. To add or
# remove a fragment, edit the `fragments` list below — that's it.
#
# Why this is a literal list and not read from $COMPOSE_FILE:
#
#   Nickel 1.17 requires `import` paths to be literals at parse time.
#   You can't write `import my_runtime_var` — the path has to be
#   visible to the parser. So we list fragments here, by name, in
#   order.
#
# If you prefer to drive the fragment list from an environment
# variable, see `wrappers/from-compose-file.sh` in this directory —
# it reads $COMPOSE_FILE, generates a temporary config.ncl with literal
# imports, and runs nickel export.

let build = import "../../lib/merge.ncl" in

let fragments = [
  import "./compose.yml",
  import "./services/web.yml",
  import "./services/db.yml",
  import "./overlays/dev.yml",
] in

build fragments