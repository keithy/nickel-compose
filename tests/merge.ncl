# tests/merge.ncl
#
# Smoke test for the merge engine. Run with `nickel eval` and check
# the output matches expectations.
#
# Usage:
#   nickel eval tests/merge.ncl

let build = import "../lib/merge.ncl" in

# Two synthetic fragments: base service + overlay that adds one env.
let base = {
  services = {
    web = {
      image = "nginx:1.27",
      environment = ["FOO=1"],
      volumes = ["data:/var/lib/data"],
    },
  },
  volumes = { data = null },
} in

let overlay = {
  services = {
    web = {
      environment = ["BAR=2"],
      volumes = ["/code:/code"],
    },
  },
} in

let result = build [base, overlay] in

# Expected after merge:
#   services.web.image = "nginx:1.27"
#   services.web.environment = ["FOO=1", "BAR=2"]   (concat)
#   services.web.volumes = ["data:/var/lib/data", "/code:/code"]  (concat)
#   services.web.networks = ["default"]  (default fill)
#   services.web.restart = "unless-stopped"  (default fill)
#   services.web.init = false  (default fill)
#   volumes.data = null
result