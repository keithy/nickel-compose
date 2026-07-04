# base.ncl — root fragment for the dummy project.
#
# Nickel-native equivalent of base.yml. Provides the shared `default`
# bridge network and the named volumes used by the web and db services.
# Both files exist side-by-side; choose which to import in your config.

{
  volumes = {
    web-data = null,
    db-data = null,
  },
  networks = {
    default = {
      driver = "bridge",
    },
  },
}