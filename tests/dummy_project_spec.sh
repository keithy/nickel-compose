#!/usr/bin/env bash
# tests/dummy_project_spec.sh — bash-spec 2.1 end-to-end tests for
# the examples/dummy-project/ fragment composition workflow.
#
# Covers direct export (config.ncl) and the NICKEL_COMPOSE wrapper
# under several input shapes (literal paths, $VAR indirection, mixed).
#
# Per bash-spec convention, the spec runs in its own directory.
# Wrapper subshells that `cd` into another dir pass absolute `--out`
# paths via `$(pwd)/out/...` so they still write under tests/out/.

cd "$(dirname "$0")"

. ./lib/bash-spec+file+jq.sh

ROOT="$(cd .. && pwd)"

rm -rf out
mkdir -p out

describe "dummy-project end-to-end" && {
  DUMMY="$ROOT/examples/dummy-project/config.ncl"

  it "renders YAML without error" && {
    mkdir -p "out/dummy"
    run nickel export --format yaml "$DUMMY" | sed -n '2,$p' > "out/dummy/compose.yaml"
    should_succeed
  }

  it "renders JSON without error" && {
    run nickel export --format json "$DUMMY" > "out/dummy/compose.json"
    should_succeed
  }

  it "YAML output matches expected snapshot" && {
    expect_no_diff "out/dummy/compose.yaml" "expected/dummy/compose.yaml"
  }

  it "config_ncl.ncl (all Nickel) produces byte-identical output" && {
    run nickel export --format yaml "$ROOT/examples/dummy-project/config_ncl.ncl" \
      | sed -n '2,$p' > "out/dummy/compose-ncl.yml"
    should_succeed
    expect_no_diff "out/dummy/compose-ncl.yml" "expected/dummy/compose.yaml"
  }

  it "config_mixed.ncl (mixed YAML + Nickel) produces byte-identical output" && {
    run nickel export --format yaml "$ROOT/examples/dummy-project/config_mixed.ncl" \
      | sed -n '2,$p' > "out/dummy/compose-mixed.yml"
    should_succeed
    expect_no_diff "out/dummy/compose-mixed.yml" "expected/dummy/compose.yaml"
  }

  it "config_no_base.ncl validates: engine synthesizes top-level volumes from services" && {
    # No base fragment, but the merge engine scans service volume
    # references and synthesizes top-level declarations. The result
    # should be valid compose — podman-compose config accepts it.
    # We render BOTH yaml (for podman-compose validation) and json
    # (for jq structural assertions — jq doesn't read YAML).
    run nickel export --format yaml "$ROOT/examples/dummy-project/config_no_base.ncl" \
      | sed -n '2,$p' > "out/dummy/compose-no-base.yml"
    should_succeed
    run nickel export --format json "$ROOT/examples/dummy-project/config_no_base.ncl" \
      > "out/dummy/compose-no-base.json"
    should_succeed
    # The synthesized top-level volumes: web-data, db-data.
    expect_jq "out/dummy/compose-no-base.json" '.volumes | has("web-data")' to_be "true"
    expect_jq "out/dummy/compose-no-base.json" '.volumes | has("db-data")'  to_be "true"
    if command -v podman-compose >/dev/null 2>&1; then
      podman-compose -f "out/dummy/compose-no-base.yml" config >/dev/null
      should_succeed
    else
      echo "(skipped — podman-compose not installed)"
      true
    fi
  }

  it "all three services present (web, db, redis)" && {
    expect_jq "out/dummy/compose.json" '.services | has("web")'   to_be "true"
    expect_jq "out/dummy/compose.json" '.services | has("db")'    to_be "true"
    expect_jq "out/dummy/compose.json" '.services | has("redis")' to_be "true"
  }

  it "db port from dev overlay is merged" && {
    expect_jq "out/dummy/compose.json" '.services.db.ports[0]' to_be "5432:5432"
  }

  it "web env from dev overlay is appended" && {
    expect_jq "out/dummy/compose.json" \
      '.services.web.environment[] | select(test("REDIS_HOST"))' \
      to_match "REDIS_HOST=redis"
  }

  it "named volumes union (web-data, db-data)" && {
    expect_jq "out/dummy/compose.json" '.volumes | has("web-data")' to_be "true"
    expect_jq "out/dummy/compose.json" '.volumes | has("db-data")'  to_be "true"
  }

  it "synthesis preserves pre-declared volume driver config" && {
    # Synthesizes web-data/db-data with null body, but base.ncl
    # declares them with null too — verify driver field exists
    # when explicitly supplied via a custom fragment.
    cat > "out/.driver-test.ncl" <<EOF
let composer = import "$ROOT/nickel-compose.ncl" in
let svc = {
  services = {
    cache = {
      image = "redis:7-alpine",
      volumes = ["cache-data:/data"],
    },
  },
} in
let driver_frag = {
  volumes = {
    "cache-data" = { driver = "local", driver_opts = { type = "nfs" } },
  },
} in
composer.merge [svc, driver_frag]
EOF
    run nickel export --format json "out/.driver-test.ncl" \
      > "out/dummy/compose-driver.json"
    should_succeed
    expect_jq "out/dummy/compose-driver.json" '.volumes."cache-data".driver' to_be "local"
    expect_jq "out/dummy/compose-driver.json" '.volumes."cache-data".driver_opts.type' to_be "nfs"
    rm -f "out/.driver-test.ncl" "out/dummy/compose-driver.json"
  }

  it "validates through podman-compose" && {
    if command -v podman-compose >/dev/null 2>&1; then
      podman-compose -f "out/dummy/compose.yaml" config >/dev/null
      should_succeed
    else
      echo "(skipped)"
      true
    fi
  }

  it "NICKEL_COMPOSE literal-only (no \$VAR refs) produces equivalent output" && {
    WRAPPER="$ROOT/scripts/from-nickel-compose.sh"
    if [[ -x "$WRAPPER" ]]; then
      # Literal-path form: NICKEL_COMPOSE='a:b:c' is the same input
      # shape as the deleted COMPOSE_FRAGMENTS wrapper.
      WRAPPER_OUT="$(pwd)/out/wrapper-output.yml"
      (
        cd "$ROOT/examples/dummy-project"
        NICKEL_COMPOSE="base.yml:services/web.yml:services/db.yml:overlays/dev.yml" \
          "$WRAPPER" --out "$WRAPPER_OUT" >/dev/null
      )
      should_succeed

      if ! diff -q "$WRAPPER_OUT" "out/dummy/compose.yaml" >/dev/null 2>&1; then
        diff "$WRAPPER_OUT" "out/dummy/compose.yaml" | head -20
        echo "literal-path wrapper output differs"
        false
      fi
      should_succeed

      rm -f "$WRAPPER_OUT"
    else
      echo "(skipped — wrapper not executable)"
      true
    fi
  }

  it "NICKEL_COMPOSE-driven wrapper (Stage 0): single env var" && {
    WRAPPER="$ROOT/scripts/from-nickel-compose.sh"
    if [[ -x "$WRAPPER" ]]; then
      WRAPPER_OUT="$(pwd)/out/wrapper-stage0.yml"
      (
        cd "$ROOT/examples/dummy-project"
        COMPOSE_FILE="base.yml:services/web.yml:services/db.yml:overlays/dev.yml" \
          NICKEL_COMPOSE='$COMPOSE_FILE' \
          "$WRAPPER" --out "$WRAPPER_OUT" >/dev/null
      )
      should_succeed

      if ! diff -q "$WRAPPER_OUT" "out/dummy/compose.yaml" >/dev/null 2>&1; then
        diff "$WRAPPER_OUT" "out/dummy/compose.yaml" | head -20
        echo "stage 0 wrapper output differs"
        false
      fi
      should_succeed

      rm -f "$WRAPPER_OUT"
    else
      echo "(skipped)"
      true
    fi
  }

  it "NICKEL_COMPOSE-driven wrapper (Stage 1): split env vars" && {
    WRAPPER="$ROOT/scripts/from-nickel-compose.sh"
    if [[ -x "$WRAPPER" ]]; then
      WRAPPER_OUT="$(pwd)/out/wrapper-stage1.yml"
      (
        cd "$ROOT/examples/dummy-project"
        COMPOSE_SERVICES="services/web.yml:services/db.yml" \
          COMPOSE_OVERLAYS="overlays/dev.yml" \
          COMPOSE_FILE="base.yml" \
          NICKEL_COMPOSE='$COMPOSE_SERVICES:$COMPOSE_OVERLAYS:$COMPOSE_FILE' \
          "$WRAPPER" --out "$WRAPPER_OUT" >/dev/null
      )
      should_succeed

      if ! diff -q "$WRAPPER_OUT" "out/dummy/compose.yaml" >/dev/null 2>&1; then
        diff "$WRAPPER_OUT" "out/dummy/compose.yaml" | head -20
        echo "stage 1 wrapper output differs"
        false
      fi
      should_succeed

      rm -f "$WRAPPER_OUT"
    else
      echo "(skipped)"
      true
    fi
  }

  it "NICKEL_COMPOSE accepts mixed literals and env-var refs" && {
    WRAPPER="$ROOT/scripts/from-nickel-compose.sh"
    if [[ -x "$WRAPPER" ]]; then
      WRAPPER_OUT="$(pwd)/out/wrapper-mixed.yml"
      (
        cd "$ROOT/examples/dummy-project"
        # Mix of literal paths and an env-var reference.
        NICKEL_COMPOSE='base.yml:services/web.yml:$REMAINING' \
          REMAINING="services/db.yml:overlays/dev.yml" \
          "$WRAPPER" --out "$WRAPPER_OUT" >/dev/null
      )
      should_succeed

      if ! diff -q "$WRAPPER_OUT" "out/dummy/compose.yaml" >/dev/null 2>&1; then
        diff "$WRAPPER_OUT" "out/dummy/compose.yaml" | head -20
        echo "mixed form wrapper output differs"
        false
      fi
      should_succeed

      rm -f "$WRAPPER_OUT"
    else
      echo "(skipped)"
      true
    fi
  }

  it "wrapper errors when NICKEL_COMPOSE is unset" && {
    WRAPPER="$ROOT/scripts/from-nickel-compose.sh"
    if [[ -x "$WRAPPER" ]]; then
      ERR_LOG="$(pwd)/out/wrapper-unset.stderr"
      (
        unset NICKEL_COMPOSE
        cd "$ROOT/examples/dummy-project"
        "$WRAPPER" --out /tmp/should-not-be-written.yml >/dev/null 2>"$ERR_LOG"
      )
      should_fail
      grep -q "NICKEL_COMPOSE not set" "$ERR_LOG"
      should_succeed
      rm -f "$ERR_LOG" /tmp/should-not-be-written.yml
    else
      echo "(skipped)"
      true
    fi
  }

  it "wrapper errors when \$VAR reference expands empty" && {
    WRAPPER="$ROOT/scripts/from-nickel-compose.sh"
    if [[ -x "$WRAPPER" ]]; then
      ERR_LOG="$(pwd)/out/wrapper-empty-var.stderr"
      (
        unset MISSING_VAR
        cd "$ROOT/examples/dummy-project"
        NICKEL_COMPOSE='$MISSING_VAR' \
          "$WRAPPER" --out /tmp/should-not-be-written.yml >/dev/null 2>"$ERR_LOG"
      )
      should_fail
      grep -q "expanded to an empty fragment list" "$ERR_LOG"
      should_succeed
      rm -f "$ERR_LOG" /tmp/should-not-be-written.yml
    else
      echo "(skipped)"
      true
    fi
  }

  it "wrapper errors when --out collides with a fragment" && {
    WRAPPER="$ROOT/scripts/from-nickel-compose.sh"
    if [[ -x "$WRAPPER" ]]; then
      ERR_LOG="$(pwd)/out/wrapper-collision.stderr"
      (
        cd "$ROOT/examples/dummy-project"
        NICKEL_COMPOSE="base.yml:services/web.yml" \
          "$WRAPPER" --out base.yml >/dev/null 2>"$ERR_LOG"
      )
      should_fail
      grep -q "would clobber source" "$ERR_LOG"
      should_succeed
      rm -f "$ERR_LOG"
    else
      echo "(skipped)"
      true
    fi
  }
}