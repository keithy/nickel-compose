# config_ncl.ncl — Stage 3 destination: all fragments as Nickel,
# with schema validation attached to the result.
#
# Same fragment order as config.ncl, but every fragment is a .ncl
# file. The merge engine treats Nickel records and YAML records
# identically — output is byte-identical to the legacy path.
#
# Use `composer.merge_with_check` (not plain `composer.merge`) so
# the result carries a `_check` field with the schema report. The
# to-compose.sh wrapper reads `_check.ok` from the result and
# exits non-zero on schema errors. See docs/schema.md for the
# full picture.
#
# Use this config when you've finished migrating fragments off YAML.

let composer = import "nickel-compose.ncl" in

let fragments = [
  import "./base.ncl",
  import "./services/web.ncl",
  import "./services/db.ncl",
  import "./overlays/dev.ncl",
] in

composer.merge_with_check fragments