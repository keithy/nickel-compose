# tests/fixtures/conditionals/without-postgres.ncl
#
# if_absent: when postgres is NOT a service, the patch fires and
# adds a local db fallback.

{
  services = {
    web = { image = "nginx" },
  },

  if_absent = {
    "services.postgres" = {
      services = {
        db = { image = "postgres:16-alpine" },
      },
    },
  },
}