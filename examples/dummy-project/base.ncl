# base.ncl — root fragment for the dummy project.
#
# Nickel-native equivalent of base.yml. Provides the shared `default`
# bridge network and the named volumes used by the web and db services.
# Both files exist side-by-side; choose which to import in your config.
#
# As of merge engine synthesis support, this file is technically
# optional for projects that use named volumes — the engine scans
# service volume references and synthesizes top-level declarations.
# But explicit declarations here give you control over volume
# driver/options that synthesis can't infer.

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