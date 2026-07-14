# tests/fixtures/conditionals/wildcard-no-match.ncl
#
# Wildcard gate with no matching service. The pattern is
# "memcached-.*" but only "redis-cache" exists. The patch should
# be skipped.

{
  services = {
    web = { image = "nginx:1.27" },
    "redis-cache" = { image = "redis:7-alpine" },
  },

  if_present = {
    "services::memcached-.*" = {
      services = {
        web = {
          environment = ["MEMCACHED_HOST=memcached"],
          depends_on = ["memcached"],
        },
      },
    },
  },
}
