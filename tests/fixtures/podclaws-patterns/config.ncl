# tests/fixtures/podclaws-patterns/config.ncl
#
# Entry point for the podclaws-patterns fixture. Imports the
# three fixtures above in order. No dependency on /code/podclaws/.

let composer = import "nickel-compose.ncl" in

let fragments = [
  import "./01-base.yml",
  import "./02-service.yml",
  import "./03-overlay.yml",
] in

composer.merge fragments