# tests/fixtures/conditionals/with-postgres.ncl
#
# if_absent: when postgres is NOT a service, provide a local
# fallback database. The patch declares its own top-level
# structure (services:) and the engine merges it at top level.

{
  services = {
    web = { image = "nginx" },
    postgres = { image = "postgres:external" },
  },

  if_absent = {
    "services::postgres" = {
      services = {
        db = { image = "postgres:16-alpine" },
      },
    },
  },
}