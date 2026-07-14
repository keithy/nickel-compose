#!/usr/bin/env bash
# tests/merge_spec.sh — bash-spec 2.1 tests for the nickel-compose
# merge engine itself (synthetic fixture + overlay behavior).
#
# Uses golden-file comparison: render outputs to tests/out/, compare
# against tests/expected/ snapshots. Set INIT=true to copy out/ over
# expected/ instead of comparing (used to update snapshots).
#
# Per bash-spec convention, the spec runs in its own directory — so
# fixtures like tests/merge.ncl and snapshots like tests/expected/...
# are bare relative paths (`out/...`, `expected/...`). Project-root
# fixtures (lib/, examples/) are referenced via $ROOT.

cd "$(dirname "$0")"

. ./lib/bash-spec+file+jq.sh

ROOT="$(cd .. && pwd)"

rm -rf out
mkdir -p out

describe "merge engine" && {

  context "synthetic fixture" && {
    FIXTURE="merge.ncl"

    it "renders to JSON" && {
      run nickel export --format json "$FIXTURE" > "out/merge.json"
      should_succeed
    }

    it "JSON output matches expected snapshot" && {
      expect_no_diff "out/merge.json" "expected/merge.json"
    }

    it "service field preservation: image kept from base" && {
      expect_jq "out/merge.json" '.services.web.image' to_be "nginx:1.27"
    }

    it "array concat: environment has both entries" && {
      expect_jq "out/merge.json" '.services.web.environment | length' to_be "2"
      expect_jq "out/merge.json" '.services.web.environment[0]' to_be "FOO=1"
      expect_jq "out/merge.json" '.services.web.environment[1]' to_be "BAR=2"
    }

    it "array concat: volumes are concatenated" && {
      expect_jq "out/merge.json" '.services.web.volumes | length' to_be "2"
    }

    it "default fill: networks, restart, init" && {
      expect_jq "out/merge.json" '.services.web.networks[0]' to_be "default"
      expect_jq "out/merge.json" '.services.web.restart'      to_be "unless-stopped"
      expect_jq "out/merge.json" '.services.web.init'         to_be "false"
    }

    it "top-level union: named volume 'data' present" && {
      expect_jq "out/merge.json" '.volumes | has("data")' to_be "true"
    }
  }

  context "overlay behavior" && {
    it "overlay networks wins over default [default]" && {
      cat > "out/.override.ncl" <<EOF
let composer = import "$ROOT/nickel-compose.ncl" in
let base = { services = { web = { image = "x" } } } in
let overlay = { services = { web = { networks = ["other"] } } } in
composer.merge [base, overlay]
EOF
      run nickel export --format json "out/.override.ncl" > "out/.override.json"
      expect_jq "out/.override.json" '.services.web.networks[0]' to_be "other"
      rm -f "out/.override.ncl" "out/.override.json"
    }
  }
}