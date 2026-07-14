# config_ncl.ncl — Stage 3 destination: all fragments as Nickel.
#
# Same fragment order as config.ncl, but every fragment is a .ncl
# file. The merge engine treats Nickel records and YAML records
# identically — output is byte-identical to the legacy path.
#
# Use this config when you've finished migrating fragments off YAML.

let nc = import "../../lib/nickel-compose.ncl" in

let fragments = [
  import "./base.ncl",
  import "./services/web.ncl",
  import "./services/db.ncl",
  import "./overlays/dev.ncl",
] in

nc.merge fragments