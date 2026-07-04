# config_mixed.ncl — partial migration demo.
#
# Three fragments are still YAML (the legacy path), one fragment
# (services/web.ncl) is Nickel. This is what an in-progress
# migration looks like: convert one fragment at a time, verify
# the rendered output stays byte-identical, repeat.
#
# Pick the fragments you most often edit, convert those first.
# Leave the rarely-edited ones (base, dev) on YAML until you
# need to touch them.

let build = import "../../lib/merge.ncl" in

let fragments = [
  import "./base.yml",
  import "./services/web.ncl",
  import "./services/db.yml",
  import "./overlays/dev.yml",
] in

build fragments