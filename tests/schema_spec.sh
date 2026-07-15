#!/usr/bin/env bash
# tests/schema_spec.sh — bash-spec 2.1 tests for the schema
# contracts and the `check` function in the merge engine.
#
# Covers:
#   - composer.Service contract exposes field-level doc/default
#   - composer.validation.check (and alias composer.check) returns
#     { ok, errors } for valid and invalid records
#   - composer.merge_with_check attaches _check to the result
#   - _check is visible in nickel eval output
#   - _check is stripped from nickel export (via strip-helper)
#   - the to-compose.sh wrapper reads _check.ok to set the exit
#     code (3 cases: true, false, absent)
#   - exit code on schema error is 1, but artifacts are still
#     produced (so podman compose config can debug)
#
# Per bash-spec convention, the spec runs in its own directory.

cd "$(dirname "$0")"

. ./lib/bash-spec+file+jq.sh

ROOT="$(cd .. && pwd)"
NC="$ROOT/nickel-compose.ncl"
TO_WRAPPER="$ROOT/scripts/to-compose.sh"

rm -rf out
mkdir -p out

export NICKEL_IMPORT_PATH="$ROOT"

describe "schema contracts" && {
  it "Service contract has field-level contracts and doc comments" && {
    cat > "out/service-contract.ncl" <<EOF
let composer = import "$NC" in
{
  is_record = std.is_record composer.Service,
  keys = std.record.fields composer.Service,
  has_image = std.record.has_field "image" composer.Service,
  has_ports = std.record.has_field "ports" composer.Service,
  has_volumes = std.record.has_field "volumes" composer.Service,
  has_environment = std.record.has_field "environment" composer.Service,
  has_depends_on = std.record.has_field "depends_on" composer.Service,
  has_networks = std.record.has_field "networks" composer.Service,
  has_command = std.record.has_field "command" composer.Service,
  has_restart = std.record.has_field "restart" composer.Service,
  has_init = std.record.has_field "init" composer.Service,
  has_build = std.record.has_field "build" composer.Service,
}
EOF
    run nickel export --format json "out/service-contract.ncl" > "out/service-contract.json"
    should_succeed
    expect_jq "out/service-contract.json" ".is_record" to_be "true"
    expect_jq "out/service-contract.json" '.keys | sort | join(",")' to_be "build,command,depends_on,environment,image,init,networks,ports,restart,volumes"
    expect_jq "out/service-contract.json" ".has_image" to_be "true"
    expect_jq "out/service-contract.json" ".has_ports" to_be "true"
  }

  it "Port, Volume, Network, Fragment contracts are exposed" && {
    cat > "out/contracts-check.ncl" <<EOF
let composer = import "$NC" in
{
  port_keys = std.record.fields composer.Port,
  volume_keys = std.record.fields composer.Volume,
  network_keys = std.record.fields composer.Network,
  fragment_keys = std.record.fields composer.Fragment,
}
EOF
    run nickel export --format json "out/contracts-check.ncl" > "out/contracts-check.json"
    should_succeed
    expect_jq "out/contracts-check.json" '.port_keys | sort | join(",")' to_be "host_ip,protocol,published,target"
    expect_jq "out/contracts-check.json" '.volume_keys | sort | join(",")' to_be "driver,driver_opts,external,name"
    expect_jq "out/contracts-check.json" '.network_keys | sort | join(",")' to_be "driver,external,name"
    expect_jq "out/contracts-check.json" '.fragment_keys | sort | join(",")' to_be "if_absent,if_present,networks,services,volumes"
  }
}

describe "composer.validation.check" && {
  it "returns ok=true on a valid merged record" && {
    cat > "out/check-ok.ncl" <<EOF
let composer = import "$NC" in
{
  result = composer.validation.check (composer.merge [
    {
      services = {
        web = { image = "nginx:1.27" },
        db = { image = "postgres:16-alpine" },
      },
    }
  ]),
}
EOF
    run nickel export --format json "out/check-ok.ncl" > "out/check-ok.json"
    should_succeed
    expect_jq "out/check-ok.json" ".result.ok" to_be "true"
    expect_jq "out/check-ok.json" ".result.errors | length" to_be "0"
  }

  it "returns ok=false with a list of errors when image is missing" && {
    cat > "out/check-missing.ncl" <<EOF
let composer = import "$NC" in
{
  result = composer.validation.check (composer.merge [
    {
      services = {
        web = { command = ["echo"] },
        db = { image = "postgres:16-alpine" },
      },
    }
  ]),
}
EOF
    run nickel export --format json "out/check-missing.ncl" > "out/check-missing.json"
    should_succeed
    expect_jq "out/check-missing.json" ".result.ok" to_be "false"
    expect_jq "out/check-missing.json" ".result.errors | length" to_be "1"
    expect_jq "out/check-missing.json" ".result.errors[0].service" to_be "web"
    expect_jq "out/check-missing.json" ".result.errors[0].field" to_be "image"
    expect_jq "out/check-missing.json" '.result.errors[0].message | test("image")' to_be "true"
    expect_jq "out/check-missing.json" '.result.errors[0].message | test("build")' to_be "true"
  }

  it "accepts a service with 'build' instead of 'image'" && {
    cat > "out/check-build.ncl" <<EOF
let composer = import "$NC" in
{
  result = composer.validation.check (composer.merge [
    {
      services = {
        web = { build = { context = "." } },
      },
    }
  ]),
}
EOF
    run nickel export --format json "out/check-build.ncl" > "out/check-build.json"
    should_succeed
    expect_jq "out/check-build.json" ".result.ok" to_be "true"
  }

  it "the top-level 'check' is the same function as validation.check" && {
    cat > "out/check-alias.ncl" <<EOF
let composer = import "$NC" in
let m = composer.merge [
  { services = { web = { image = "x" } } },
] in
{
  top_level = composer.check m,
  namespaced = composer.validation.check m,
  are_equal = (composer.check m).ok == (composer.validation.check m).ok,
}
EOF
    run nickel export --format json "out/check-alias.ncl" > "out/check-alias.json"
    should_succeed
    expect_jq "out/check-alias.json" ".are_equal" to_be "true"
  }
}

describe "composer.merge_with_check" && {
  it "attaches _check to the result, visible to nickel eval" && {
    cat > "out/with-check.ncl" <<EOF
let composer = import "$NC" in
{
  result = composer.merge_with_check [
    { services = { web = { image = "nginx:1.27" } } },
  ],
  has_check = std.record.has_field "_check" (composer.merge_with_check [
    { services = { web = { image = "nginx:1.27" } } },
  ]),
}
EOF
    run nickel eval "out/with-check.ncl" > "out/with-check.eval" 2>&1 || true
    # The eval output uses Nickel record syntax; check the eval
    # form has _check.
    grep -q "_check" "out/with-check.eval"
    should_succeed
  }

  it "the attached _check has ok and errors fields" && {
    cat > "out/check-shape.ncl" <<EOF
let composer = import "$NC" in
let m = composer.merge_with_check [
  { services = { web = { image = "x" } } },
] in
{
  has_ok = std.record.has_field "ok" m._check,
  has_errors = std.record.has_field "errors" m._check,
  ok = m._check.ok,
  errors_empty = std.array.length m._check.errors == 0,
}
EOF
    run nickel export --format json "out/check-shape.ncl" > "out/check-shape.json"
    should_succeed
    expect_jq "out/check-shape.json" ".has_ok" to_be "true"
    expect_jq "out/check-shape.json" ".has_errors" to_be "true"
    expect_jq "out/check-shape.json" ".ok" to_be "true"
    expect_jq "out/check-shape.json" ".errors_empty" to_be "true"
  }

  it "_check is excluded from rendered JSON when not round-tripped through eval" && {
    # When a user does `nickel export config.ncl` directly
    # (config.ncl written by hand, not produced by `nickel
    # eval`), the `not_exported` annotation on _check is
    # honored — the field is stripped. This is the case for
    # direct CLI use; the to-compose wrapper has a different
    # round-trip behavior because `nickel eval` serializes
    # without the annotation.
    cat > "out/with-check-json.ncl" <<EOF
let composer = import "$NC" in
composer.merge_with_check [
  { services = { web = { image = "nginx:1.27" } } },
]
EOF
    run nickel export --format json "out/with-check-json.ncl" > "out/with-check.json"
    should_succeed
    # _check should not be in the output.
    expect_jq "out/with-check.json" 'has("_check")' to_be "false"
  }
}

describe "to-compose.sh integration" && {
  it "produces compose.ncl + compose.yaml, exits 0, schema ok" && {
    cat > "out/good-config.ncl" <<EOF
let composer = import "nickel-compose.ncl" in
let fragments = [
  { services = { web = { image = "nginx:1.27" } } },
] in
composer.merge_with_check fragments
EOF
    run "$TO_WRAPPER" --in "out/good-config.ncl" --out "out/good.yaml" 2>"out/good.stderr"
    should_succeed
    expect "out/good.ncl" to_exist
    expect "out/good.yaml" to_exist
    # The schema summary lands on stderr.
    grep -q "schema: ok" "out/good.stderr"
    should_succeed
    # The yaml does not contain _check.
    if grep -q "^_check:" "out/good.yaml"; then
      echo "FAIL: _check leaked into compose.yaml"
      false
    fi
    should_succeed
  }

  it "exits non-zero on schema failure but still produces artifacts" && {
    cat > "out/bad-config.ncl" <<EOF
let composer = import "nickel-compose.ncl" in
let fragments = [
  { services = { web = { command = ["echo"] } } },
] in
composer.merge_with_check fragments
EOF
    run "$TO_WRAPPER" --in "out/bad-config.ncl" --out "out/bad.yaml" 2>"out/bad.stderr"
    should_fail
    # The artifacts still exist (so `podman compose config`
    # can debug the broken state).
    expect "out/bad.ncl" to_exist
    expect "out/bad.yaml" to_exist
    # The schema summary lands on stderr.
    grep -q "schema: errors" "out/bad.stderr"
    should_succeed
    # The .ncl has the _check field with the error.
    grep -q "_check" "out/bad.ncl"
    should_succeed
  }

  it "plain 'merge' is treated as schema-not-checked (backward compat)" && {
    cat > "out/legacy-config.ncl" <<EOF
let composer = import "nickel-compose.ncl" in
let fragments = [
  { services = { web = { image = "nginx:1.27" } } },
] in
composer.merge fragments
EOF
    run "$TO_WRAPPER" --in "out/legacy-config.ncl" --out "out/legacy.yaml" 2>"out/legacy.stderr"
    should_succeed
    grep -q "schema: not checked" "out/legacy.stderr"
    should_succeed
  }
}
