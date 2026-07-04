#!/usr/bin/env bash
# tests/conditionals_spec.sh — bash-spec 2.1 tests for the
# if_present conditional-patch feature in the merge engine.
#
# Each fragment can declare a conditional patch:
#
#   if_present:
#     <gate-field>.<gate-value>:
#       <patch-fields-mirroring-merged-<gate-field>>
#
# When merged.<gate-field>.<gate-value> exists, the patch is
# applied via merge_records. Otherwise, the patch is skipped.
# if_present itself is stripped from the output (compose
# doesn't recognize the field).
#
# Per bash-spec convention, the spec runs in its own directory.

cd "$(dirname "$0")"

. ./lib/bash-spec+file+jq.sh

ROOT="$(cd .. && pwd)"
BUILD="let build = import \"$ROOT/lib/merge.ncl\" in"
FIXTURE_WITH="$ROOT/tests/fixtures/conditionals/with-redis.ncl"
FIXTURE_WITHOUT="$ROOT/tests/fixtures/conditionals/without-redis.ncl"

rm -rf out
mkdir -p out

describe "if_present conditionals" && {
  it "renders with-redis fixture to JSON" && {
    # Wrap the fixture in a build call so the engine actually
    # processes the conditional, not just outputs the raw record.
    cat > "out/with-redis.ncl" <<EOF
$BUILD
build [ import "$FIXTURE_WITH" ]
EOF
    run nickel export --format json "out/with-redis.ncl" > "out/with-redis.json"
    should_succeed
  }

  it "renders without-redis fixture to JSON" && {
    cat > "out/without-redis.ncl" <<EOF
$BUILD
build [ import "$FIXTURE_WITHOUT" ]
EOF
    run nickel export --format json "out/without-redis.ncl" > "out/without-redis.json"
    should_succeed
  }

  it "applies the patch when the gated service is present" && {
    # When redis service exists, web.environment gains REDIS_HOST,
    # and web.depends_on gains redis.
    expect_jq "out/with-redis.json" '.services.web.environment[]' to_match 'REDIS_HOST=redis'
    expect_jq "out/with-redis.json" '.services.web.environment[]' to_match 'REDIS_PORT=6379'
    expect_jq "out/with-redis.json" '.services.web.depends_on[0]' to_be "redis"
  }

  it "skips the patch when the gated service is absent" && {
    # When redis is missing, web stays dependency-free.
    expect_jq "out/without-redis.json" '.services.web | has("environment")' to_be "false"
    expect_jq "out/without-redis.json" '.services.web.depends_on | length' to_be "0"
  }

  it "strips if_present from the rendered output" && {
    expect_jq "out/with-redis.json" 'has("if_present")' to_be "false"
    expect_jq "out/without-redis.json" 'has("if_present")' to_be "false"
  }
}

describe "if_absent conditionals" && {
  FIXTURE_WITH_PG="$ROOT/tests/fixtures/conditionals/with-postgres.ncl"
  FIXTURE_WITHOUT_PG="$ROOT/tests/fixtures/conditionals/without-postgres.ncl"

  it "renders with-postgres fixture to JSON" && {
    cat > "out/with-postgres.ncl" <<EOF
$BUILD
build [ import "$FIXTURE_WITH_PG" ]
EOF
    run nickel export --format json "out/with-postgres.ncl" > "out/with-postgres.json"
    should_succeed
  }

  it "renders without-postgres fixture to JSON" && {
    cat > "out/without-postgres.ncl" <<EOF
$BUILD
build [ import "$FIXTURE_WITHOUT_PG" ]
EOF
    run nickel export --format json "out/without-postgres.ncl" > "out/without-postgres.json"
    should_succeed
  }

  it "skips the patch when the gated service is present" && {
    # When postgres is present, the local fallback db is not added.
    expect_jq "out/with-postgres.json" '.services | has("db")' to_be "false"
  }

  it "applies the patch when the gated service is absent" && {
    # When postgres is missing, a local db fallback is added.
    expect_jq "out/without-postgres.json" '.services.db.image' to_be "postgres:16-alpine"
  }

  it "strips if_absent from the rendered output" && {
    expect_jq "out/with-postgres.json" 'has("if_absent")' to_be "false"
    expect_jq "out/without-postgres.json" 'has("if_absent")' to_be "false"
  }
}