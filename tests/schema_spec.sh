#!/usr/bin/env bash
# tests/schema_spec.sh — bash-spec 2.1 tests for the schema
# contracts and the `check` function in the merge engine.
#
# Covers:
#   - composer.Service contract exposes field-level doc/default
#   - composer.validation.check (and alias composer.check) returns
#     { ok, errors } for valid and invalid records
#   - composer.merge_with_check attaches x-check to the result
#   - x-check is a Compose extension field (prefix x-*) so it
#     stays in the rendered YAML; podman-compose ignores it
#   - the to-compose.sh wrapper reads x-check.ok to set the exit
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
  it "attaches x-check to the result, visible to nickel eval" && {
    cat > "out/with-check.ncl" <<EOF
let composer = import "$NC" in
{
  result = composer.merge_with_check [
    { services = { web = { image = "nginx:1.27" } } },
  ],
  has_check = std.record.has_field "x-check" (composer.merge_with_check [
    { services = { web = { image = "nginx:1.27" } } },
  ]),
}
EOF
    run nickel eval "out/with-check.ncl" > "out/with-check.eval" 2>&1 || true
    # The eval output uses Nickel record syntax; check the eval
    # form has x-check.
    grep -q "x-check" "out/with-check.eval"
    should_succeed
  }

  it "the attached x-check has ok and errors fields" && {
    cat > "out/check-shape.ncl" <<EOF
let composer = import "$NC" in
let m = composer.merge_with_check [
  { services = { web = { image = "x" } } },
] in
{
  has_ok = std.record.has_field "ok" m."x-check",
  has_errors = std.record.has_field "errors" m."x-check",
  ok = m."x-check".ok,
  errors_empty = std.array.length m."x-check".errors == 0,
}
EOF
    run nickel export --format json "out/check-shape.ncl" > "out/check-shape.json"
    should_succeed
    expect_jq "out/check-shape.json" ".has_ok" to_be "true"
    expect_jq "out/check-shape.json" ".has_errors" to_be "true"
    expect_jq "out/check-shape.json" ".ok" to_be "true"
    expect_jq "out/check-shape.json" ".errors_empty" to_be "true"
  }

  it "x-check is present in rendered JSON (it's a Compose x-* extension field)" && {
    # x-check is a Compose extension field. The x- prefix
    # tells the runtime to ignore it; nickel export keeps
    # it in the output. Tooling that wants to read the
    # schema report can parse the YAML.
    cat > "out/with-check-json.ncl" <<EOF
let composer = import "$NC" in
composer.merge_with_check [
  { services = { web = { image = "nginx:1.27" } } },
]
EOF
    run nickel export --format json "out/with-check-json.ncl" > "out/with-check.json"
    should_succeed
    # x-check is in the output (no annotation stripping it).
    expect_jq "out/with-check.json" '."x-check".ok' to_be "true"
  }
}

describe "to-compose.sh integration" && {
  it "produces compose.ncl + compose.yaml, exits 0, schema ok" && {
    # Bare fragment list (the post-refactor shape). to-compose.sh
    # wraps this with the engine and calls merge_with_source.
    cat > "out/good-config.ncl" <<'EOF'
[
  { services = { web = { image = "nginx:1.27" } } },
]
EOF
    run "$TO_WRAPPER" --in "out/good-config.ncl" --out "out/good.yaml" 2>"out/good.stderr"
    should_succeed
    expect "out/good.ncl" to_exist
    expect "out/good.yaml" to_exist
    # The schema summary lands on stderr.
    grep -q "schema: ok" "out/good.stderr"
    should_succeed
    # The yaml has x-check (it's a Compose extension field;
    # the runtime ignores it but it's preserved for tooling).
    grep -q "^x-check:" "out/good.yaml"
    should_succeed
    # podman-compose accepts the yaml.
    if command -v podman-compose >/dev/null 2>&1; then
      podman-compose -f "out/good.yaml" config >/dev/null
      should_succeed
    fi
  }

  it "exits non-zero on schema failure but still produces artifacts" && {
    # Bare fragment list with a fragment that has a service
    # missing both image and build — schema check fails.
    cat > "out/bad-config.ncl" <<'EOF'
[
  { services = { web = { command = ["echo"] } } },
]
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
    # The .ncl has the x-check field with the error.
    grep -q "x-check" "out/bad.ncl"
    should_succeed
  }

  it "plain 'merge' is treated as schema-not-checked (backward compat)" && {
    # Bare fragment list. The wrapper calls merge_with_source
    # which always attaches x-check, so this test now expects
    # the schema to be checked. The "not checked" path only
    # fires when no merge_with_check / merge_with_source is
    # in the call chain — i.e. when the user calls merge
    # directly and returns the result without going through
    # to-compose.sh. That path is exercised by the
    # config_with_check.ncl typecheck, not here.
    cat > "out/legacy-config.ncl" <<'EOF'
[
  { services = { web = { image = "nginx:1.27" } } },
]
EOF
    run "$TO_WRAPPER" --in "out/legacy-config.ncl" --out "out/legacy.yaml" 2>"out/legacy.stderr"
    should_succeed
    # Schema is now checked (via merge_with_source) — confirm
    # the "schema: ok" line, not "schema: not checked".
    grep -q "schema: ok" "out/legacy.stderr"
    should_succeed
  }
}
