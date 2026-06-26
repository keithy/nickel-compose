# config.ncl — first-time user entry point.
#
# Drop this file into a project that already uses docker-compose / podman-compose
# fragments and a `COMPOSE_FILE=frag1.yml:frag2.yml:...` env var to combine
# them. Nickel will:
#
#   1. Read $COMPOSE_FILE from the environment (set by your mise cd hook or
#      your shell).
#   2. Treat the colon-separated list as the fragment order.
#   3. Merge them with Compose semantics (scalars later-win, arrays concat,
#      records recurse, services/volumes/networks union).
#   4. Auto-fill defaults per service (networks, restart, init).
#   5. Export the result as `podman-compose.yml` at the project root.
#
# You don't need to edit this file to add or remove fragments — change
# COMPOSE_FILE in `.env` and re-run `mise run render`.
#
# For an existing podclaws-style project, the migration is:
#
#   git add nickel-compose/        # add the submodule
#   cp examples/dummy-project/config.ncl ./config.ncl
#   # edit config.ncl's `fragments` list to match your COMPOSE_FILE
#   mise trust && mise install
#   mise run render
#
# Then delete the picker script and the .env-compose file — the .ncl
# file replaces both.

let build = import "../../lib/merge.ncl" in

# --- Fragment list ------------------------------------------------------
#
# Replace this list with your project's fragments. Order matters:
# later fragments override scalars and concat arrays. This example
# matches the YAML files in this directory.
#
# If your project already uses COMPOSE_FILE=frag1.yml:frag2.yml:...
# to combine fragments, you can read it from the environment instead:
#
#   let compose_file = std.env_var_or "COMPOSE_FILE" "compose.yml" in
#   let paths = std.string.split ":" compose_file in
#   let fragments = std.array.map (fun p => import p) paths in
#
# That makes this config.ncl a drop-in replacement for your existing
# .env-compose picker.

let fragments = [
  import "./compose.yml",
  import "./services/web.yml",
  import "./services/db.yml",
  import "./overlays/dev.yml",
] in

build fragments