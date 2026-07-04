# tests/fixtures/conditionals/without-redis.ncl
#
# Same fragment minus the redis service. With redis absent, the
# if_present patch is gated out and web stays dependency-free.

{
  services = {
    web = { image = "nginx:1.27" },
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