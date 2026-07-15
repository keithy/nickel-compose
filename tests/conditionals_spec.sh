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
# NICKEL_IMPORT_PATH lets the fixtures use `import "nickel-compose.ncl"`
# without a path prefix. Set it once per spec.
export NICKEL_IMPORT_PATH="$ROOT"
BUILD="let composer = import \"nickel-compose.ncl\" in"
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
composer.merge [ import "$FIXTURE_WITH" ]
EOF
    run nickel export --format json "out/with-redis.ncl" > "out/with-redis.json"
    should_succeed
  }

  it "renders without-redis fixture to JSON" && {
    cat > "out/without-redis.ncl" <<EOF
$BUILD
composer.merge [ import "$FIXTURE_WITHOUT" ]
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

describe "if_present wildcard gates" && {
  FIXTURE_WC_MATCH="$ROOT/tests/fixtures/conditionals/wildcard-redis.ncl"
  FIXTURE_WC_NOMATCH="$ROOT/tests/fixtures/conditionals/wildcard-no-match.ncl"

  it "applies the patch when a wildcard pattern matches a service name" && {
    # The gate is "services::redis-.*" which matches "redis-cache"
    # and "redis-sentinel". Since at least one matches, the patch
    # fires and web gains REDIS_HOST.
    cat > "out/wildcard-match.ncl" <<EOF
$BUILD
composer.merge [ import "$FIXTURE_WC_MATCH" ]
EOF
    run nickel export --format json "out/wildcard-match.ncl" > "out/wildcard-match.json"
    should_succeed
    expect_jq "out/wildcard-match.json" '.services.web.environment[]' to_match 'REDIS_HOST'
    expect_jq "out/wildcard-match.json" '.services.web.depends_on[0]' to_be "redis-cache"
  }

  it "skips the patch when no field name matches the wildcard" && {
    # The gate is "services::memcached-.*" but only redis-cache
    # exists. No match, patch is skipped.
    cat > "out/wildcard-nomatch.ncl" <<EOF
$BUILD
composer.merge [ import "$FIXTURE_WC_NOMATCH" ]
EOF
    run nickel export --format json "out/wildcard-nomatch.ncl" > "out/wildcard-nomatch.json"
    should_succeed
    expect_jq "out/wildcard-nomatch.json" '.services.web | has("environment")' to_be "false"
  }

  it "treats exact names without wildcards as literal regex (dot is literal)" && {
    # A gate value with a dot (e.g. "my.app") should match a
    # service literally named "my.app", not "myxapp". This is
    # the key reason we don't just use shell glob — we anchor
    # and escape properly.
    cat > "out/dot-literal.ncl" <<EOF
$BUILD
composer.merge [
  {
    services = {
      web = { image = "nginx:1.27" },
      "my.app" = { image = "x" },
    },
    if_present = {
      "services::my\\\\.app" = {
        services = {
          web = { environment = ["APP=my.app"] },
        },
      },
    },
  }
]
EOF
    run nickel export --format json "out/dot-literal.ncl" > "out/dot-literal.json"
    should_succeed
    expect_jq "out/dot-literal.json" '.services.web.environment[]' to_match 'APP=my.app'
  }
}

describe "if_absent conditionals" && {
  FIXTURE_WITH_PG="$ROOT/tests/fixtures/conditionals/with-postgres.ncl"
  FIXTURE_WITHOUT_PG="$ROOT/tests/fixtures/conditionals/without-postgres.ncl"

  it "renders with-postgres fixture to JSON" && {
    cat > "out/with-postgres.ncl" <<EOF
$BUILD
composer.merge [ import "$FIXTURE_WITH_PG" ]
EOF
    run nickel export --format json "out/with-postgres.ncl" > "out/with-postgres.json"
    should_succeed
  }

  it "renders without-postgres fixture to JSON" && {
    cat > "out/without-postgres.ncl" <<EOF
$BUILD
composer.merge [ import "$FIXTURE_WITHOUT_PG" ]
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

describe "conditional resolution order" && {
  # When both if_absent and if_present gates are met (in different
  # fragments), both patches apply. Order: if_absent first, then
  # if_present. For array fields, both entries concatenate with
  # if_absent's value first.
  FIXTURE_ORDER="$ROOT/tests/fixtures/conditionals/order.ncl"

  it "applies both patches in order: if_absent first, then if_present" && {
    # The order fixture has both conditional blocks. The test adds
    # a second fragment declaring postgres — that makes the
    # if_present.services.postgres gate met. The redis service is
    # NOT declared, so if_absent.services.redis also fires.
    cat > "out/order.ncl" <<EOF
$BUILD
composer.merge [
  import "$FIXTURE_ORDER",
  { services = { postgres = { image = "postgres:external" } } },
]
EOF
    run nickel export --format json "out/order.ncl" > "out/order.json"
    should_succeed
  }

  it "concatenates environment entries from both gates in resolve order" && {
    # Both patches add to web.environment. Order: FROM_ABSENT
    # first (if_absent resolves first), then FROM_PRESENT
    # (if_present resolves second).
    expect_jq "out/order.json" '.services.web.environment[0]' to_be "FROM_ABSENT"
    expect_jq "out/order.json" '.services.web.environment[1]' to_be "FROM_PRESENT"
  }
}