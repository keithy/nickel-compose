# config_ncl.ncl — Stage 3 destination: all fragments as Nickel,
# with schema validation attached to the result.
#
# Same fragment order as config.ncl, but every fragment is a .ncl
# file. The merge engine treats Nickel records and YAML records
# identically — output is byte-identical to the legacy path.
#
# Bare fragment list. The use script wraps this with the engine
# and calls composer.merge_with_source, which attaches an
# `x-check` field carrying the schema report. x-check is a
# Compose extension field (prefix x-*), so the runtime ignores
# it but tooling can read it. The to-compose.sh wrapper reads
# `x-check.ok` from the result and exits non-zero on schema
# errors. See docs/schema.md for the full picture.
#
# Use this config when you've finished migrating fragments off YAML.

[
  import "./base.ncl",
  import "./services/web.ncl",
  import "./services/db.ncl",
  import "./overlays/dev.ncl",
]
