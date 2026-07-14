#!/usr/bin/env bash
# tests/typecheck_spec.sh — bash-spec 2.1 typecheck assertions for
# nickel-compose sources.
#
# Per bash-spec convention, the spec runs in its own directory.

cd "$(dirname "$0")"

. ./lib/bash-spec+file+jq.sh

ROOT="$(cd .. && pwd)"

describe "typecheck" && {
  it "nickel-compose.ncl typechecks" && {
    run nickel typecheck "$ROOT/nickel-compose.ncl"
    should_succeed
  }

  it "examples/dummy-project/config.ncl typechecks" && {
    run nickel typecheck "$ROOT/examples/dummy-project/config.ncl"
    should_succeed
  }

  it "examples/dummy-project/config_ncl.ncl (all Nickel) typechecks" && {
    run nickel typecheck "$ROOT/examples/dummy-project/config_ncl.ncl"
    should_succeed
  }

  it "examples/dummy-project/config_mixed.ncl (mixed YAML+Nickel) typechecks" && {
    run nickel typecheck "$ROOT/examples/dummy-project/config_mixed.ncl"
    should_succeed
  }

  it "examples/dummy-project/config_no_base.ncl (synthesis demo) typechecks" && {
    run nickel typecheck "$ROOT/examples/dummy-project/config_no_base.ncl"
    should_succeed
  }

  it "individual Nickel fragments typecheck" && {
    for frag in \
      "$ROOT/examples/dummy-project/base.ncl" \
      "$ROOT/examples/dummy-project/services/web.ncl" \
      "$ROOT/examples/dummy-project/services/db.ncl" \
      "$ROOT/examples/dummy-project/overlays/dev.ncl"; do
      run nickel typecheck "$frag"
      should_succeed
    done
  }

  it "exports merge, version, and placeholder namespaces (report, discover, validation)" && {
    # The engine exports a record with the main merge function,
    # a version string, and three placeholder namespaces (empty
    # records) for future report/discover/validation sub-functions.
    cat > "out/namespace-check.ncl" <<EOF
let composer = import "$ROOT/nickel-compose.ncl" in
{
  has_merge = std.record.has_field "merge" composer,
  has_version = std.record.has_field "version" composer,
  has_report = std.record.has_field "report" composer,
  has_discover = std.record.has_field "discover" composer,
  has_validation = std.record.has_field "validation" composer,
  version_is_string = std.is_string composer.version,
}
EOF
    run nickel export --format json "out/namespace-check.ncl" > "out/namespace-check.json"
    should_succeed
    expect_jq "out/namespace-check.json" ".has_merge" to_be "true"
    expect_jq "out/namespace-check.json" ".has_version" to_be "true"
    expect_jq "out/namespace-check.json" ".has_report" to_be "true"
    expect_jq "out/namespace-check.json" ".has_discover" to_be "true"
    expect_jq "out/namespace-check.json" ".has_validation" to_be "true"
    expect_jq "out/namespace-check.json" ".version_is_string" to_be "true"
  }
}