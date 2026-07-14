#!/usr/bin/env bash
# tests/typecheck_spec.sh — bash-spec 2.1 typecheck assertions for
# nickel-compose sources.
#
# Per bash-spec convention, the spec runs in its own directory.

cd "$(dirname "$0")"

. ./lib/bash-spec+file+jq.sh

ROOT="$(cd .. && pwd)"

describe "typecheck" && {
  it "lib/nickel-compose.ncl typechecks" && {
    run nickel typecheck "$ROOT/lib/nickel-compose.ncl"
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
}