#!/usr/bin/env bash
# tests/dummy_project_spec.sh — bash-spec 2.1 end-to-end tests for
# the examples/dummy-project/ fragment composition workflow.
#
# Covers direct export (config.ncl) and the two wrapper entry points
# (COMPOSE_FRAGMENTS, NICKEL_COMPOSE). Uses golden-file comparison
# against tests/expected/dummy/ — set INIT=true to regenerate.
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
    run nickel export --format yaml "$DUMMY" | sed -n '2,$p' > "out/dummy/compose.yml"
    should_succeed
  }

  it "renders JSON without error" && {
    run nickel export --format json "$DUMMY" > "out/dummy/compose.json"
    should_succeed
  }

  it "YAML output matches expected snapshot" && {
    expect_no_diff "out/dummy/compose.yml" "expected/dummy/compose.yml"
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

  it "validates through podman-compose" && {
    if command -v podman-compose >/dev/null 2>&1; then
      podman-compose -f "out/dummy/compose.yml" config >/dev/null
      should_succeed
    else
      echo "(skipped)"
      true
    fi
  }

  it "COMPOSE_FRAGMENTS-driven wrapper produces equivalent output" && {
    WRAPPER="$ROOT/wrappers/from-compose-file.sh"
    if [[ -x "$WRAPPER" ]]; then
      # Write wrapper output to a tmp path so we don't clobber the
      # source base.yml (which the wrapper would otherwise overwrite
      # because the default output filename is compose.yml — but if
      # the source fragment were also compose.yml that would collide,
      # hence the rename to base.yml in the dummy project).
      WRAPPER_OUT="$(pwd)/out/wrapper-output.yml"
      (
        cd "$ROOT/examples/dummy-project"
        COMPOSE_FRAGMENTS="base.yml:services/web.yml:services/db.yml:overlays/dev.yml" \
          "$WRAPPER" --out "$WRAPPER_OUT" >/dev/null
      )
      should_succeed

      if ! diff -q "$WRAPPER_OUT" "out/dummy/compose.yml" >/dev/null 2>&1; then
        diff "$WRAPPER_OUT" "out/dummy/compose.yml" | head -20
        echo "wrapper output differs from direct export"
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
    WRAPPER="$ROOT/wrappers/from-nickel-compose.sh"
    if [[ -x "$WRAPPER" ]]; then
      WRAPPER_OUT="$(pwd)/out/wrapper-stage0.yml"
      (
        cd "$ROOT/examples/dummy-project"
        COMPOSE_FILE="base.yml:services/web.yml:services/db.yml:overlays/dev.yml" \
          NICKEL_COMPOSE='$COMPOSE_FILE' \
          "$WRAPPER" --out "$WRAPPER_OUT" >/dev/null
      )
      should_succeed

      if ! diff -q "$WRAPPER_OUT" "out/dummy/compose.yml" >/dev/null 2>&1; then
        diff "$WRAPPER_OUT" "out/dummy/compose.yml" | head -20
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
    WRAPPER="$ROOT/wrappers/from-nickel-compose.sh"
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

      if ! diff -q "$WRAPPER_OUT" "out/dummy/compose.yml" >/dev/null 2>&1; then
        diff "$WRAPPER_OUT" "out/dummy/compose.yml" | head -20
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
    WRAPPER="$ROOT/wrappers/from-nickel-compose.sh"
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

      if ! diff -q "$WRAPPER_OUT" "out/dummy/compose.yml" >/dev/null 2>&1; then
        diff "$WRAPPER_OUT" "out/dummy/compose.yml" | head -20
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
}