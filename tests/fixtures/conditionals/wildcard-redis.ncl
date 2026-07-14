# tests/fixtures/conditionals/wildcard-redis.ncl
#
# Single fragment exercising wildcard gates. Uses services::redis-*
# to match any service whose name starts with "redis-". When the
# user includes redis, redis-cache, or redis-sentinel, web gets
# REDIS_HOST. When none of those are selected, the patch is skipped.

{
  services = {
    web = { image = "nginx:1.27" },
    "redis-cache" = { image = "redis:7-alpine" },
    "redis-sentinel" = { image = "redis:7-alpine" },
  },

  if_present = {
    "services::redis-.*" = {
      services = {
        web = {
          environment = ["REDIS_HOST=redis-cache"],
          depends_on = ["redis-cache"],
        },
      },
    },
  },
}
