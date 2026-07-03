#!/usr/bin/env bash
# tests/merge_spec.sh — bash-spec 2.1 tests for the nickel-compose merge engine.
#
# Uses golden-file comparison: render outputs to tests/out/, compare
# against tests/expected/ snapshots. Set INIT=true to copy out/ over
# expected/ instead of comparing (used to update snapshots).
#
# Renders tests/merge.ncl and examples/dummy-project/config.ncl to
# JSON and YAML, then asserts with bash-spec matchers.
#
# Per bash-spec convention, the spec runs in its own directory — so
# fixtures like tests/merge.ncl and snapshots like tests/expected/...
# are bare relative paths (`out/...`, `expected/...`). Project-root
# fixtures (lib/, examples/) are referenced via $ROOT. Wrapper
# subshells that `cd` into another dir pass absolute `--out` paths
# via `$(pwd)/out/...` so they still write under tests/out/.

cd "$(dirname "$0")"

. ./lib/bash-spec+file+jq.sh

ROOT="$(cd .. && pwd)"

rm -rf out
mkdir -p out

describe "nickel-compose merge engine" && {

  context "typecheck" && {
    it "lib/merge.ncl typechecks" && {
      run nickel typecheck "$ROOT/lib/merge.ncl"
      should_succeed
    }

    it "examples/dummy-project/config.ncl typechecks" && {
      run nickel typecheck "$ROOT/examples/dummy-project/config.ncl"
      should_succeed
    }
  }

  context "merge engine: synthetic fixture" && {
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
      expect_jq "out/merge.json" '.services.web.restart' to_be "unless-stopped"
      expect_jq "out/merge.json" '.services.web.init' to_be "false"
    }

    it "top-level union: named volume 'data' present" && {
      expect_jq "out/merge.json" '.volumes | has("data")' to_be "true"
    }
  }

  context "overlay behavior" && {
    it "overlay networks wins over default [default]" && {
      cat > "out/.override.ncl" <<EOF
let build = import "$ROOT/lib/merge.ncl" in
let base = { services = { web = { image = "x" } } } in
let overlay = { services = { web = { networks = ["other"] } } } in
build [base, overlay]
EOF
      run nickel export --format json "out/.override.ncl" > "out/.override.json"
      expect_jq "out/.override.json" '.services.web.networks[0]' to_be "other"
      rm -f "out/.override.ncl" "out/.override.json"
    }
  }

  context "end-to-end with dummy-project example" && {
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
      WRAPPER="$ROOT/examples/dummy-project/wrappers/from-compose-file.sh"
      if [[ -x "$WRAPPER" ]]; then
        # Write wrapper output to a tmp path so we don't clobber the
        # source base.yml (which the wrapper would otherwise overwrite
        # because the default output filename is compose.yml — but if
        # the source fragment were also compose.yml that would
        # collide, hence the rename to base.yml in the dummy project).
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
      WRAPPER="$ROOT/examples/dummy-project/wrappers/from-nickel-compose.sh"
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
      WRAPPER="$ROOT/examples/dummy-project/wrappers/from-nickel-compose.sh"
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
      WRAPPER="$ROOT/examples/dummy-project/wrappers/from-nickel-compose.sh"
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

  context "end-to-end with podclaws example (optional)" && {
    # Skipped in CI — depends on /code/podclaws YAML paths.
    EXAMPLE="$ROOT/examples/podclaws/config.ncl"

    it "renders YAML without error" && {
      if [[ -f "$EXAMPLE" ]] && [[ -f "/code/podclaws/compose.yml" ]]; then
        mkdir -p "out/podclaws"
        run nickel export --format yaml "$EXAMPLE" | sed -n '2,$p' > "out/podclaws/compose.yml"
        should_succeed
      else
        echo "(skipped — no /code/podclaws/compose.yml)"
        true
      fi
    }

    it "validates through podman-compose" && {
      if command -v podman-compose >/dev/null 2>&1 && [[ -f "out/podclaws/compose.yml" ]]; then
        GOCLAW_GATEWAY_TOKEN=test podman-compose -f "out/podclaws/compose.yml" config >/dev/null
        should_succeed
      else
        echo "(skipped)"
        true
      fi
    }

    # Cleanup: only present locally (not CI). Remove so subsequent
    # runs start fresh.
    rm -rf "out/podclaws"
  }
}