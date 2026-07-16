#!/usr/bin/env bash
# tests/typecheck_spec.sh — bash-spec 2.1 typecheck assertions for
# nickel-compose sources.
#
# Per bash-spec convention, the spec runs in its own directory.

cd "$(dirname "$0")"

. ./lib/bash-spec+file+jq.sh

ROOT="$(cd .. && pwd)"
# NICKEL_IMPORT_PATH lets the fixtures use `import "nickel-compose.ncl"`
# without a path prefix. Set it once per spec.
export NICKEL_IMPORT_PATH="$ROOT"

mkdir -p out

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

  it "examples/dummy-project/config_with_check.ncl (explicit check call) typechecks" && {
    run nickel typecheck "$ROOT/examples/dummy-project/config_with_check.ncl"
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

  it "exports merge, merge_fully_validate, check, Service, version, and namespaces" && {
    # The engine exports a record with: the main merge function,
    # merge_fully_validate (with embedded schema check + source
    # tracking), the Service contract, the validation.check
    # function (also exposed as a top-level for ergonomics), a
    # version string, and three namespaces (report, discover,
    # validation).
    cat > "out/namespace-check.ncl" <<EOF
let composer = import "nickel-compose.ncl" in
{
  has_merge = std.record.has_field "merge" composer,
  has_merge_fully_validate = std.record.has_field "merge_fully_validate" composer,
  has_check = std.record.has_field "check" composer,
  has_service = std.record.has_field "Service" composer,
  has_version = std.record.has_field "version" composer,
  has_report = std.record.has_field "report" composer,
  has_discover = std.record.has_field "discover" composer,
  has_validation = std.record.has_field "validation" composer,
  has_validation_check = std.record.has_field "check" composer.validation,
  version_is_string = std.is_string composer.version,
  check_is_function = std.is_function composer.check,
  merge_fully_validate_is_function = std.is_function composer.merge_fully_validate,
  service_has_image = std.record.has_field "image" composer.Service,
  service_has_ports = std.record.has_field "ports" composer.Service,
  has_port = std.record.has_field "Port" composer,
  has_volume = std.record.has_field "Volume" composer,
  has_network = std.record.has_field "Network" composer,
  has_fragment = std.record.has_field "Fragment" composer,
  port_has_target = std.record.has_field "target" composer.Port,
  volume_has_driver = std.record.has_field "driver" composer.Volume,
  network_has_driver = std.record.has_field "driver" composer.Network,
  fragment_has_services = std.record.has_field "services" composer.Fragment,
}
EOF
    run nickel export --format json "out/namespace-check.ncl" > "out/namespace-check.json"
    should_succeed
    expect_jq "out/namespace-check.json" ".has_merge" to_be "true"
    expect_jq "out/namespace-check.json" ".has_merge_fully_validate" to_be "true"
    expect_jq "out/namespace-check.json" ".has_check" to_be "true"
    expect_jq "out/namespace-check.json" ".has_service" to_be "true"
    expect_jq "out/namespace-check.json" ".has_version" to_be "true"
    expect_jq "out/namespace-check.json" ".has_report" to_be "true"
    expect_jq "out/namespace-check.json" ".has_discover" to_be "true"
    expect_jq "out/namespace-check.json" ".has_validation" to_be "true"
    expect_jq "out/namespace-check.json" ".has_validation_check" to_be "true"
    expect_jq "out/namespace-check.json" ".version_is_string" to_be "true"
    expect_jq "out/namespace-check.json" ".check_is_function" to_be "true"
    expect_jq "out/namespace-check.json" ".merge_fully_validate_is_function" to_be "true"
    expect_jq "out/namespace-check.json" ".service_has_image" to_be "true"
    expect_jq "out/namespace-check.json" ".service_has_ports" to_be "true"
    expect_jq "out/namespace-check.json" ".has_port" to_be "true"
    expect_jq "out/namespace-check.json" ".has_volume" to_be "true"
    expect_jq "out/namespace-check.json" ".has_network" to_be "true"
    expect_jq "out/namespace-check.json" ".has_fragment" to_be "true"
    expect_jq "out/namespace-check.json" ".port_has_target" to_be "true"
    expect_jq "out/namespace-check.json" ".volume_has_driver" to_be "true"
    expect_jq "out/namespace-check.json" ".network_has_driver" to_be "true"
    expect_jq "out/namespace-check.json" ".fragment_has_services" to_be "true"
  }

  it "exposes the version as 0.2.0" && {
    cat > "out/version-check.ncl" <<EOF
let composer = import "nickel-compose.ncl" in
composer.version
EOF
    run nickel export --format json "out/version-check.ncl" > "out/version-check.json"
    should_succeed
    expect_jq "out/version-check.json" to_be "\"0.2.0\""
  }
}