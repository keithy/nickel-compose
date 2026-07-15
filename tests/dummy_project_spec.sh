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
# NICKEL_IMPORT_PATH lets the fixtures use `import "nickel-compose.ncl"`
# without a path prefix. Set it once per spec.
export NICKEL_IMPORT_PATH="$ROOT"
FROM_WRAPPER="$ROOT/scripts/from-nickel-compose.sh"
TO_WRAPPER="$ROOT/scripts/to-compose.sh"

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
let composer = import "nickel-compose.ncl" in
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

  it "two-step flow: NICKEL_COMPOSE literal-only produces equivalent output" && {
    # Run the from- wrapper (produces config.ncl) then the to-
    # wrapper (renders compose.ncl + compose.yaml). The result
    # should match the golden snapshot produced by direct
    # `nickel export config.ncl`.
    if [[ -x "$FROM_WRAPPER" && -x "$TO_WRAPPER" ]]; then
      (
        cd "$ROOT/examples/dummy-project"
        NICKEL_COMPOSE="base.yml:services/web.yml:services/db.yml:overlays/dev.yml" \
          "$FROM_WRAPPER" --out out/twostep-config.ncl >/dev/null
      )
      should_succeed

      "$TO_WRAPPER" --in "$ROOT/examples/dummy-project/out/twostep-config.ncl" \
        --out "out/wrapper-literal.yaml" >/dev/null
      should_succeed

      if ! diff -q "out/wrapper-literal.yaml" "out/dummy/compose.yaml" >/dev/null 2>&1; then
        diff "out/wrapper-literal.yaml" "out/dummy/compose.yaml" | head -20
        echo "literal-path two-step output differs from golden"
        false
      fi
      should_succeed

      rm -f "out/wrapper-literal.yaml" "out/wrapper-literal.ncl" \
            "$ROOT/examples/dummy-project/out/twostep-config.ncl"
    else
      echo "(skipped — wrapper not executable)"
      true
    fi
  }

  it "two-step flow: compose.ncl is canonical and importable" && {
    # The .ncl is the source of truth: it must be a valid Nickel
    # file that, when imported, exposes the merged record. The
    # .yaml is a one-way projection of the same record.
    if [[ -x "$FROM_WRAPPER" && -x "$TO_WRAPPER" ]]; then
      (
        cd "$ROOT/examples/dummy-project"
        NICKEL_COMPOSE="base.yml:services/web.yml:services/db.yml:overlays/dev.yml" \
          "$FROM_WRAPPER" --out out/twostep-config.ncl >/dev/null
      )
      should_succeed
      "$TO_WRAPPER" --in "$ROOT/examples/dummy-project/out/twostep-config.ncl" \
        --out "out/twostep.yaml" >/dev/null
      should_succeed

      NCL_AT="out/twostep.ncl"
      expect "$NCL_AT" to_exist
      expect "out/twostep.yaml" to_exist

      cat > "out/check-ncl.ncl" <<EOF
let merged = import "$(pwd)/$NCL_AT" in
{
  ncl_service_count = std.array.length (std.record.fields merged.services),
  ncl_has_networks = std.record.has_field "networks" merged,
  ncl_has_volumes = std.record.has_field "volumes" merged,
}
EOF
      run nickel export --format json "out/check-ncl.ncl" > "out/check-ncl.json"
      should_succeed
      expect_jq "out/check-ncl.json" ".ncl_service_count" to_be "3"
      expect_jq "out/check-ncl.json" ".ncl_has_networks" to_be "true"
      expect_jq "out/check-ncl.json" ".ncl_has_volumes" to_be "true"

      # Round-trip: deriving .yaml from .ncl must match the
      # two-step's .yaml output. Both go through `nickel
      # export` directly; the x-check field is preserved
      # in both (Compose's x-* extension fields are kept
      # by nickel export and ignored at runtime). The
      # comparison is byte-equality of the rendered YAML.
      run nickel export --format yaml "$NCL_AT" \
        | sed -n '2,$p' > "out/twostep-derived.yaml"
      if ! diff -q "out/twostep-derived.yaml" "out/twostep.yaml" >/dev/null 2>&1; then
        diff "out/twostep-derived.yaml" "out/twostep.yaml" | head -20
        echo "derived yaml does not match two-step output"
        false
      fi
      should_succeed

      rm -f "out/twostep.yaml" "out/twostep.ncl" "out/twostep-derived.yaml" \
            "out/check-ncl.ncl" "out/check-ncl.json" \
            "$ROOT/examples/dummy-project/out/twostep-config.ncl"
    else
      echo "(skipped — wrapper not executable)"
      true
    fi
  }

  it "two-step flow (Stage 0): NICKEL_COMPOSE='\$COMPOSE_FILE'" && {
    if [[ -x "$FROM_WRAPPER" && -x "$TO_WRAPPER" ]]; then
      (
        cd "$ROOT/examples/dummy-project"
        COMPOSE_FILE="base.yml:services/web.yml:services/db.yml:overlays/dev.yml" \
          NICKEL_COMPOSE='$COMPOSE_FILE' \
          "$FROM_WRAPPER" --out out/twostep-config.ncl >/dev/null
      )
      should_succeed
      "$TO_WRAPPER" --in "$ROOT/examples/dummy-project/out/twostep-config.ncl" \
        --out "out/stage0.yaml" >/dev/null
      should_succeed
      if ! diff -q "out/stage0.yaml" "out/dummy/compose.yaml" >/dev/null 2>&1; then
        diff "out/stage0.yaml" "out/dummy/compose.yaml" | head -20
        echo "stage 0 output differs from golden"
        false
      fi
      should_succeed
      rm -f "out/stage0.yaml" "out/stage0.ncl" \
            "$ROOT/examples/dummy-project/out/twostep-config.ncl"
    else
      echo "(skipped)"
      true
    fi
  }

  it "two-step flow (Stage 1): split env vars" && {
    if [[ -x "$FROM_WRAPPER" && -x "$TO_WRAPPER" ]]; then
      (
        cd "$ROOT/examples/dummy-project"
        COMPOSE_SERVICES="services/web.yml:services/db.yml" \
          COMPOSE_OVERLAYS="overlays/dev.yml" \
          COMPOSE_FILE="base.yml" \
          NICKEL_COMPOSE='$COMPOSE_SERVICES:$COMPOSE_OVERLAYS:$COMPOSE_FILE' \
          "$FROM_WRAPPER" --out out/twostep-config.ncl >/dev/null
      )
      should_succeed
      "$TO_WRAPPER" --in "$ROOT/examples/dummy-project/out/twostep-config.ncl" \
        --out "out/stage1.yaml" >/dev/null
      should_succeed
      if ! diff -q "out/stage1.yaml" "out/dummy/compose.yaml" >/dev/null 2>&1; then
        diff "out/stage1.yaml" "out/dummy/compose.yaml" | head -20
        echo "stage 1 output differs from golden"
        false
      fi
      should_succeed
      rm -f "out/stage1.yaml" "out/stage1.ncl" \
            "$ROOT/examples/dummy-project/out/twostep-config.ncl"
    else
      echo "(skipped)"
      true
    fi
  }

  it "two-step flow: NICKEL_COMPOSE accepts mixed literals and env-var refs" && {
    if [[ -x "$FROM_WRAPPER" && -x "$TO_WRAPPER" ]]; then
      (
        cd "$ROOT/examples/dummy-project"
        NICKEL_COMPOSE='base.yml:services/web.yml:$REMAINING' \
          REMAINING="services/db.yml:overlays/dev.yml" \
          "$FROM_WRAPPER" --out out/twostep-config.ncl >/dev/null
      )
      should_succeed
      "$TO_WRAPPER" --in "$ROOT/examples/dummy-project/out/twostep-config.ncl" \
        --out "out/mixed.yaml" >/dev/null
      should_succeed
      if ! diff -q "out/mixed.yaml" "out/dummy/compose.yaml" >/dev/null 2>&1; then
        diff "out/mixed.yaml" "out/dummy/compose.yaml" | head -20
        echo "mixed form output differs from golden"
        false
      fi
      should_succeed
      rm -f "out/mixed.yaml" "out/mixed.ncl" \
            "$ROOT/examples/dummy-project/out/twostep-config.ncl"
    else
      echo "(skipped)"
      true
    fi
  }

  it "from-nickel-compose errors when NICKEL_COMPOSE is unset" && {
    if [[ -x "$FROM_WRAPPER" ]]; then
      ERR_LOG="$(pwd)/out/wrapper-unset.stderr"
      (
        unset NICKEL_COMPOSE
        cd "$ROOT/examples/dummy-project"
        "$FROM_WRAPPER" --out out/twostep-config.ncl >/dev/null 2>"$ERR_LOG"
      )
      should_fail
      grep -q "NICKEL_COMPOSE not set" "$ERR_LOG"
      should_succeed
      rm -f "$ERR_LOG"
    else
      echo "(skipped)"
      true
    fi
  }

  it "from-nickel-compose errors when \$VAR reference expands empty" && {
    if [[ -x "$FROM_WRAPPER" ]]; then
      ERR_LOG="$(pwd)/out/wrapper-empty.stderr"
      (
        cd "$ROOT/examples/dummy-project"
        NICKEL_COMPOSE='$UNSET_VAR' \
          "$FROM_WRAPPER" --out out/twostep-config.ncl >/dev/null 2>"$ERR_LOG"
      )
      should_fail
      grep -q "empty fragment list" "$ERR_LOG"
      should_succeed
      rm -f "$ERR_LOG"
    else
      echo "(skipped)"
      true
    fi
  }

  it "from-nickel-compose errors when --out collides with a fragment" && {
    if [[ -x "$FROM_WRAPPER" ]]; then
      ERR_LOG="$(pwd)/out/wrapper-collision.stderr"
      (
        cd "$ROOT/examples/dummy-project"
        NICKEL_COMPOSE="base.yml:services/web.yml" \
          "$FROM_WRAPPER" --out base.yml >/dev/null 2>"$ERR_LOG"
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