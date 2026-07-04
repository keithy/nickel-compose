# config_no_base.ncl — services and overlays only, no base fragment.
#
# Demonstrates that the merge engine synthesizes top-level volume
# and network declarations from what services reference. With
# services declaring `web-data:/var/www/html` and
# `db-data:/var/lib/postgres/data`, the engine emits:
#
#   volumes:
#     web-data: null
#     db-data: null
#
# at the top level — no base fragment needed. This makes
# nickel-compose usable for projects that don't want to maintain
# a separate root fragment just to declare volumes their services
# already reference.
#
# Use an explicit base fragment if you need to set volume drivers,
# network drivers, or other options that synthesis can't infer
# (synthesized entries are always `null` body).

let build = import "../../lib/merge.ncl" in

let fragments = [
  import "./services/web.ncl",
  import "./services/db.ncl",
  import "./overlays/dev.ncl",
] in

build fragments