# examples/podclaws/config.ncl
#
# Example: podclaws deployment using nickel-compose.
#
# Bare fragment list. The use verb wraps this with the engine
# and calls composer.merge_fully_validate.
#
# Selection happens here. Comment out a line to skip. Order
# matters: later fragments override scalars and concat arrays.
#
# Usage:
#   nickel-compose use config.ncl
#   podman-compose -f compose.yaml config
#
# Tested with nickel 1.17.0 + podman-compose 1.6.0.

[
  import "/code/podclaws/compose.yml",
  import "/code/podclaws/use/goclaw/service.goclaw.yml",
  import "/code/podclaws/use/goclaw/+code.yml",
  import "/code/podclaws/use/goclaw/+self-improve.yml",
  import "/code/podclaws/podman/+network-fix.yml",
]
