# config.ncl — first-time user entry point.
#
# This file lists the compose fragments to merge, in order. To add or
# remove a fragment, edit the list below — that's it.
#
# The file is a bare fragment list. The `use` script (or
# `scripts/to-compose.sh`) wraps it with the engine and calls
# `composer.merge_with_source` at eval time. You do not need to
# import the engine or call the merge function here.
#
# Why this is a literal list and not read from $COMPOSE_FILE:
#
#   Nickel 1.17 requires `import` paths to be literals at parse time.
#   You can't write `import my_runtime_var` — the path has to be
#   visible to the parser. So we list fragments here, by name, in
#   order.
#
# To regenerate this file from a curated fragment list, pipe the
# candidates through `../../scripts/dc2nc.sh --pick` and redirect
# to this path:
#
#   find . \( -name '*.yml' -o -name '*.ncl' \) \
#     | ../../scripts/dc2nc.sh --pick base.yml \
#                              --pick services/web.yml \
#                              --pick services/db.yml \
#                              --pick overlays/dev.yml \
#     > config.ncl
#
# Or write the bare list by hand — it's just imports.

[
  import "./base.yml",
  import "./services/web.yml",
  import "./services/db.yml",
  import "./overlays/dev.yml",
]
