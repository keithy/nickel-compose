#!/usr/bin/env bash
# tests/typecheck_spec.sh — bash-spec 2.1 typecheck assertions for
# nickel-compose sources.
#
# Per bash-spec convention, the spec runs in its own directory.

cd "$(dirname "$0")"

. ./lib/bash-spec+file+jq.sh

ROOT="$(cd .. && pwd)"

describe "typecheck" && {
  it "lib/merge.ncl typechecks" && {
    run nickel typecheck "$ROOT/lib/merge.ncl"
    should_succeed
  }

  it "examples/dummy-project/config.ncl typechecks" && {
    run nickel typecheck "$ROOT/examples/dummy-project/config.ncl"
    should_succeed
  }
}