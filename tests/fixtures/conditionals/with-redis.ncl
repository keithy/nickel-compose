# tests/fixtures/conditionals/with-redis.ncl
#
# Single fragment exercising if_present: when the user includes
# `redis` in their selection, web gets REDIS_HOST and depends_on.
# When redis is excluded, the patch doesn't fire.
#
# Patch shape: the patch declares its own top-level structure. Since
# the patch needs to add fields to a service, it starts with
# `services:`. The engine merges the patch at top level, so the
# `services:` key naturally lands in merged.services.

{
  services = {
    web = { image = "nginx:1.27" },
    redis = { image = "redis:7-alpine" },
  },

  if_present = {
    "services.redis" = {
      services = {
        web = {
          environment = ["REDIS_HOST=redis", "REDIS_PORT=6379"],
          depends_on = ["redis"],
        },
      },
    },
  },
}