# examples/podclaws/config.ncl
#
# Example: podclaws deployment using nickel-compose.
#
# Imports YAML fragments from the podclaws repo, merges them with
# Compose semantics, and exports a single podman-compose.yml.
#
# Usage:
#   nickel export --format yaml examples/podclaws/config.ncl > podman-compose.yml
#   podman-compose -f podman-compose.yml config
#
# Tested with nickel 1.17.0 + podman-compose 1.6.0.

let build = import "../../lib/merge.ncl" in

# Fragments — selection happens here. Comment out a line to skip.
# Order matters: later fragments override scalars and concat arrays.
let fragments = [
  import "/code/podclaws/compose.yml",
  import "/code/podclaws/use/goclaw/service.goclaw.yml",
  import "/code/podclaws/use/goclaw/+code.yml",
  import "/code/podclaws/use/goclaw/+self-improve.yml",
  import "/code/podclaws/podman/+network-fix.yml",
] in

build fragments