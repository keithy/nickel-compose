# config_with_check.ncl — Stage 3+ with explicit schema validation.
#
# Same fragments as config_ncl.ncl, but uses plain `composer.merge`
# and then calls `composer.check` explicitly. The two forms are
# equivalent in effect; this one shows the pattern for users who
# want to do additional processing on the merged record between
# merge and check.
#
# In production use `composer.merge_fully_validate` (see config_ncl.ncl)
# so the result carries the x-check and x-source fields for tooling.

let composer = import "nickel-compose.ncl" in

let fragments = [
  import "./base.ncl",
  import "./services/web.ncl",
  import "./services/db.ncl",
  import "./overlays/dev.ncl",
] in

let merged = composer.merge fragments in

# schema report — same shape merge_fully_validate produces
let report = composer.check merged in

# surface schema state to callers / tooling
{
  merged = merged,
  report = report,
}
