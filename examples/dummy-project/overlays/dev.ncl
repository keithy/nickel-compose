# overlays/dev.ncl — local development overlay.
#
# Nickel-native equivalent of overlays/dev.yml. Exposes the db port,
# adds a Redis sidecar, and threads REDIS_HOST/REDIS_PORT into web's
# environment.

{
  services = {
    web = {
      environment = [
        "REDIS_HOST=redis",
        "REDIS_PORT=6379",
      ],
    },
    db = {
      ports = ["5432:5432"],
    },
    redis = {
      image = "redis:7-alpine",
      command = "redis-server --appendonly yes",
    },
  },
}