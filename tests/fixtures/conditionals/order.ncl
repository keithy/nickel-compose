# tests/fixtures/conditionals/order.ncl
#
# Both patches touch the same field (services.web.environment).
# Both gates' conditions are met (in separate fragments that get
# merged in via the test):
#   - if_absent.services.redis: redis is NOT a service → fires
#   - if_present.services.postgres: postgres IS a service → fires
# Resolution order: if_absent first, then if_present. Since
# environment is in array_fields, both entries concatenate, with
# if_absent's entry appearing first.

{
  services = {
    web = { image = "nginx" },
  },

  if_absent = {
    "services::redis" = {
      services = {
        web = {
          environment = ["FROM_ABSENT"],
        },
      },
    },
  },

  if_present = {
    "services::postgres" = {
      services = {
        web = {
          environment = ["FROM_PRESENT"],
        },
      },
    },
  },
}