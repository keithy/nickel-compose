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
NC_RUN="$ROOT/scripts/nickel-compose-run.sh"

rm -rf out
mkdir -p out

# The two-step flow: run from- in the dummy-project dir, then to- in
# the test dir, then diff the result against the golden. Used by
# four tests that vary only in NICKEL_COMPOSE shape.
#
#   run_twostep "literal-path-list"         # literal colon list
#   run_twostep '$COMPOSE_FILE'             # one env-var ref (set extra via $@)
#   run_twostep '$A:$B'                     # multiple env-var refs
#
# Any extra args are passed as env vars to the subshell, so the
# caller can set COMPOSE_FILE etc. without polluting the test
# environment.
run_twostep() {
  local compose_value="$1"
  shift
  if [[ ! -x "$FROM_WRAPPER" || ! -x "$TO_WRAPPER" ]]; then
    echo "(skipped — wrapper not executable)"
    return 0
  fi
  local config="$ROOT/examples/dummy-project/out/twostep-config.ncl"
  (
    cd "$ROOT/examples/dummy-project"
    NICKEL_COMPOSE="$compose_value" "$@" \
      "$FROM_WRAPPER" --out out/twostep-config.ncl >/dev/null
  )
  should_succeed
  "$TO_WRAPPER" --in "$config" --out "out/twostep.yaml" >/dev/null
  should_succeed
  expect_no_diff_no_xsource "out/twostep.yaml" "out/dummy/compose.yaml"
  rm -f "out/twostep.yaml" "out/twostep.ncl" "$config"
}

describe "dummy-project end-to-end" && {
  DUMMY="$ROOT/examples/dummy-project/config.ncl"

  it "renders YAML without error" && {
    mkdir -p "out/dummy"
    run "$TO_WRAPPER" --in "$DUMMY" --out "$(pwd)/out/dummy/compose.yaml"
    should_succeed
  }

  it "renders JSON without error" && {
    # to-compose.sh emits yaml; for JSON we use nickel-compose-run
    # directly (the underlying engine) and pipe through nickel
    # export --format json.
    run "$NC_RUN" --format json \
      --out "$(pwd)/out/dummy/compose.json" \
      fragments="$DUMMY" -- \
      'compose.merge_with_source fragments _paths.fragments'
    should_succeed
  }

  it "YAML output matches expected snapshot" && {
    expect_no_diff_no_xsource "out/dummy/compose.yaml" "expected/dummy/compose.yaml"
  }

  it "config_ncl.ncl (all Nickel) produces byte-identical output" && {
    run "$TO_WRAPPER" \
      --in "$ROOT/examples/dummy-project/config_ncl.ncl" \
      --out "$(pwd)/out/dummy/compose-ncl.yml"
    should_succeed
    expect_no_diff_no_xsource "out/dummy/compose-ncl.yml" "expected/dummy/compose.yaml"
  }

  it "config_mixed.ncl (mixed YAML + Nickel) produces byte-identical output" && {
    run "$TO_WRAPPER" \
      --in "$ROOT/examples/dummy-project/config_mixed.ncl" \
      --out "$(pwd)/out/dummy/compose-mixed.yml"
    should_succeed
    expect_no_diff_no_xsource "out/dummy/compose-mixed.yml" "expected/dummy/compose.yaml"
  }

  it "config_no_base.ncl validates: engine synthesizes top-level volumes from services" && {
    # No base fragment, but the merge engine scans service volume
    # references and synthesizes top-level declarations. The result
    # should be valid compose — podman-compose config accepts it.
    # We render BOTH yaml (for podman-compose validation) and json
    # (for jq structural assertions — jq doesn't read YAML).
    run "$TO_WRAPPER" \
      --in "$ROOT/examples/dummy-project/config_no_base.ncl" \
      --out "$(pwd)/out/dummy/compose-no-base.yml"
    should_succeed
    run "$NC_RUN" --format json \
      --out "$(pwd)/out/dummy/compose-no-base.json" \
      fragments="$ROOT/examples/dummy-project/config_no_base.ncl" -- \
      'compose.merge_with_source fragments _paths.fragments'
    should_succeed
    # The synthesized top-level volumes: web-data, db-data.
    expect_jq "out/dummy/compose-no-base.json" '.volumes | has("web-data")' to_be "true"
    expect_jq "out/dummy/compose-no-base.json" '.volumes | has("db-data")'  to_be "true"
    expect_podman_compose "out/dummy/compose-no-base.yml"
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
    expect_podman_compose "out/dummy/compose.yaml"
  }

  it "two-step flow: NICKEL_COMPOSE literal-only produces equivalent output" && {
    run_twostep "base.yml:services/web.yml:services/db.yml:overlays/dev.yml"
  }

  it "two-step flow: compose.ncl is canonical and importable" && {
    # The .ncl is the source of truth: it must be a valid Nickel
    # file that, when imported, exposes the merged record. The
    # .yaml is a one-way projection of the same record.
    if [[ -x "$FROM_WRAPPER" && -x "$TO_WRAPPER" ]]; then
      local config="$ROOT/examples/dummy-project/out/twostep-config.ncl"
      (
        cd "$ROOT/examples/dummy-project"
        NICKEL_COMPOSE="base.yml:services/web.yml:services/db.yml:overlays/dev.yml" \
          "$FROM_WRAPPER" --out out/twostep-config.ncl >/dev/null
      )
      should_succeed
      "$TO_WRAPPER" --in "$config" --out "out/twostep.yaml" >/dev/null
      should_succeed

      local ncl_at="out/twostep.ncl"
      expect "$ncl_at" to_exist
      expect "out/twostep.yaml" to_exist

      cat > "out/check-ncl.ncl" <<EOF
let merged = import "$(pwd)/$ncl_at" in
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
      # export` directly.
      run nickel export --format yaml "$ncl_at" \
        | sed -n '2,$p' > "out/twostep-derived.yaml"
      expect_no_diff_no_xsource "out/twostep-derived.yaml" "out/twostep.yaml"

      rm -f "out/twostep.yaml" "out/twostep.ncl" "out/twostep-derived.yaml" \
            "out/check-ncl.ncl" "out/check-ncl.json" "$config"
    else
      echo "(skipped — wrapper not executable)"
      true
    fi
  }

  it "two-step flow (Stage 0): NICKEL_COMPOSE='\$COMPOSE_FILE'" && {
    run_twostep '$COMPOSE_FILE' \
      COMPOSE_FILE="base.yml:services/web.yml:services/db.yml:overlays/dev.yml"
  }

  it "two-step flow (Stage 1): split env vars" && {
    run_twostep '$COMPOSE_SERVICES:$COMPOSE_OVERLAYS:$COMPOSE_FILE' \
      COMPOSE_SERVICES="services/web.yml:services/db.yml" \
      COMPOSE_OVERLAYS="overlays/dev.yml" \
      COMPOSE_FILE="base.yml"
  }

  it "two-step flow: NICKEL_COMPOSE accepts mixed literals and env-var refs" && {
    run_twostep 'base.yml:services/web.yml:$REMAINING' \
      REMAINING="services/db.yml:overlays/dev.yml"
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

  it "x-source in the rendered yaml is the literal path the user typed" && {
    # x-source is the LITERAL path the user passed to `use`,
    # not the absolute path the tool resolved. This keeps
    # build artifacts reproducible across machines.
    # Write a self-contained config (no fragment imports) so
    # we can run it from any cwd.
    mkdir -p "out/literal-src/sub" "out/literal-src/out"
    cat > "out/literal-src/sub/config.ncl" <<'EOF'
[
  { services = { web = { image = "nginx:1.27" } } },
]
EOF
    (
      cd "out/literal-src"
      "$TO_WRAPPER" --in "sub/config.ncl" --out "out/x.yaml" >/dev/null 2>&1
    )
    should_succeed
    # x-source must be the literal relative path.
    SRC_LINE="$(grep '^x-source:' "out/literal-src/out/x.yaml")"
    if [[ "$SRC_LINE" == *"sub/config.ncl"* ]]; then
      true
    else
      echo "x-source did not contain literal 'sub/config.ncl': $SRC_LINE"
      false
    fi
    should_succeed
    # And the absolute prefix (the test dir path) must NOT
    # appear — that's the whole point of literal.
    if [[ "$SRC_LINE" == *"$ROOT"* || "$SRC_LINE" == *"/out/literal-src"* ]]; then
      echo "x-source leaked an absolute path: $SRC_LINE"
      false
    fi
    should_succeed
    rm -rf "out/literal-src"
  }
}
