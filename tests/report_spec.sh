#!/usr/bin/env bash
# tests/report_spec.sh — bash-spec 2.1 tests for composer.report.*
# (the report namespace of the merge engine).
#
# report.services returns a list of service names from a merged
# record. report.ports returns a list of host port bindings
# (with service attribution). Both handle empty inputs and the
# various port-string forms.
#
# Per bash-spec convention, the spec runs in its own directory.

cd "$(dirname "$0")"

. ./lib/bash-spec+file+jq.sh

ROOT="$(cd .. && pwd)"
NC="$ROOT/nickel-compose.ncl"

rm -rf out/report
mkdir -p out/report

describe "composer.report.services" && {

  it "returns service names from a merged record" && {
    cat > "out/report/services.ncl" <<EOF
let composer = import "$NC" in
{
  result = composer.report.services (composer.merge [
    {
      services = {
        web = { image = "nginx:1.27" },
        db = { image = "postgres:16-alpine" },
        redis = { image = "redis:7-alpine" },
      },
    }
  ]),
}
EOF
    run nickel export --format json "out/report/services.ncl" > "out/report/services.json"
    should_succeed
    expect_jq "out/report/services.json" ".result | length" to_be "3"
    expect_jq "out/report/services.json" ".result | sort | join(\",\")" to_be "db,redis,web"
  }

  it "returns empty list when no services" && {
    cat > "out/report/empty.ncl" <<EOF
let composer = import "$NC" in
{
  result = composer.report.services (composer.merge [
    { networks = { default = { driver = "bridge" } } }
  ]),
}
EOF
    run nickel export --format json "out/report/empty.ncl" > "out/report/empty.json"
    should_succeed
    expect_jq "out/report/empty.json" ".result" to_be "[]"
  }

  it "returns empty list when no fragments have services" && {
    cat > "out/report/empty2.ncl" <<EOF
let composer = import "$NC" in
{
  result = composer.report.services (composer.merge []),
}
EOF
    run nickel export --format json "out/report/empty2.ncl" > "out/report/empty2.json"
    should_succeed
    expect_jq "out/report/empty2.json" ".result" to_be "[]"
  }
}

describe "composer.report.ports" && {

  it "returns one entry per host port binding (short form string)" && {
    cat > "out/report/ports-short.ncl" <<EOF
let composer = import "$NC" in
{
  result = composer.report.ports (composer.merge [
    {
      services = {
        web = { image = "nginx:1.27", ports = ["8080:80", "443:443"] },
        db = { image = "postgres:16-alpine" },
      },
    }
  ]),
}
EOF
    run nickel export --format json "out/report/ports-short.ncl" > "out/report/ports-short.json"
    should_succeed
    expect_jq "out/report/ports-short.json" ".result | length" to_be "2"
    # Sorted by host_port: 443 before 8080
    expect_jq "out/report/ports-short.json" ".result[0].service" to_be "web"
    expect_jq "out/report/ports-short.json" ".result[0].host_port" to_be "443"
    expect_jq "out/report/ports-short.json" ".result[0].container_port" to_be "443"
    expect_jq "out/report/ports-short.json" ".result[0].protocol" to_be "tcp"
    expect_jq "out/report/ports-short.json" ".result[1].host_port" to_be "8080"
    expect_jq "out/report/ports-short.json" ".result[1].container_port" to_be "80"
  }

  it "handles long-form port objects (target + published)" && {
    cat > "out/report/ports-long.ncl" <<EOF
let composer = import "$NC" in
{
  result = composer.report.ports (composer.merge [
    {
      services = {
        web = {
          image = "nginx:1.27",
          ports = [
            { target = 80, published = 8080, protocol = "tcp" },
            { target = 443, published = 8443, protocol = "tcp" },
          ],
        },
      },
    }
  ]),
}
EOF
    run nickel export --format json "out/report/ports-long.ncl" > "out/report/ports-long.json"
    should_succeed
    expect_jq "out/report/ports-long.json" ".result | length" to_be "2"
    expect_jq "out/report/ports-long.json" ".result[0].host_port" to_be "8080"
    expect_jq "out/report/ports-long.json" ".result[0].container_port" to_be "80"
    expect_jq "out/report/ports-long.json" ".result[0].protocol" to_be "tcp"
  }

  it "skips container-only ports (no published)" && {
    cat > "out/report/ports-container-only.ncl" <<EOF
let composer = import "$NC" in
{
  result = composer.report.ports (composer.merge [
    {
      services = {
        web = {
          image = "nginx:1.27",
          ports = [
            { target = 80 },
            { target = 443, published = 8443 },
          ],
        },
      },
    }
  ]),
}
EOF
    run nickel export --format json "out/report/ports-container-only.ncl" > "out/report/ports-container-only.json"
    should_succeed
    # Only the second entry has published; the first is skipped.
    expect_jq "out/report/ports-container-only.json" ".result | length" to_be "1"
    expect_jq "out/report/ports-container-only.json" ".result[0].host_port" to_be "8443"
  }

  it "skips services with no ports" && {
    cat > "out/report/ports-none.ncl" <<EOF
let composer = import "$NC" in
{
  result = composer.report.ports (composer.merge [
    {
      services = {
        web = { image = "nginx:1.27" },
        db = { image = "postgres:16-alpine", ports = ["5432:5432"] },
      },
    }
  ]),
}
EOF
    run nickel export --format json "out/report/ports-none.ncl" > "out/report/ports-none.json"
    should_succeed
    expect_jq "out/report/ports-none.json" ".result | length" to_be "1"
    expect_jq "out/report/ports-none.json" ".result[0].service" to_be "db"
  }

  it "returns empty list when no services have ports" && {
    cat > "out/report/ports-empty.ncl" <<EOF
let composer = import "$NC" in
{
  result = composer.report.ports (composer.merge [
    { services = { web = { image = "nginx:1.27" } } }
  ]),
}
EOF
    run nickel export --format json "out/report/ports-empty.ncl" > "out/report/ports-empty.json"
    should_succeed
    expect_jq "out/report/ports-empty.json" ".result" to_be "[]"
  }

  it "attributes ports to the right service" && {
    cat > "out/report/ports-multi.ncl" <<EOF
let composer = import "$NC" in
{
  result = composer.report.ports (composer.merge [
    {
      services = {
        web = { image = "nginx:1.27", ports = ["8080:80"] },
        admin = { image = "admin:latest", ports = ["9090:9090"] },
      },
    }
  ]),
}
EOF
    run nickel export --format json "out/report/ports-multi.ncl" > "out/report/ports-multi.json"
    should_succeed
    expect_jq "out/report/ports-multi.json" ".result | length" to_be "2"
    # Sorted by host_port ascending: 8080 before 9090.
    expect_jq "out/report/ports-multi.json" ".result[0].service" to_be "web"
    expect_jq "out/report/ports-multi.json" ".result[1].service" to_be "admin"
  }

  it "defaults protocol to tcp when unspecified" && {
    cat > "out/report/ports-proto.ncl" <<EOF
let composer = import "$NC" in
{
  result = composer.report.ports (composer.merge [
    {
      services = {
        web = { image = "nginx:1.27", ports = ["8080:80"] },
      },
    }
  ]),
}
EOF
    run nickel export --format json "out/report/ports-proto.ncl" > "out/report/ports-proto.json"
    should_succeed
    expect_jq "out/report/ports-proto.json" ".result[0].protocol" to_be "tcp"
  }
}
