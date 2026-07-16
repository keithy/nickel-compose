#!/usr/bin/env bash
# tests/dummy_project_spec.sh — bash-spec 2.1 end-to-end tests for
# the examples/dummy-project/ fragment composition workflow.
#
# Covers direct export (config.ncl), the dc2nc.sh fragment picker,
# and bin/nickel-compose use's NICKEL_COMPOSE fallback.
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
# NICKEL_COMPOSE_ROOT lets the bin/ dispatcher (and its helper
# scripts) locate the engine file via a stable env var rather
# than script-adjacent paths.
export NICKEL_COMPOSE_ROOT="$ROOT"
# Put the new bin/ on PATH so the dispatcher's verb-scripts and
# the helper scripts in scripts/ can resolve by bare name.
export PATH="$ROOT/bin:$ROOT/scripts:$PATH"
TO_WRAPPER="$ROOT/scripts/to-compose.sh"
NC_RUN="$ROOT/bin/nickel-compose-run.sh"
DC2NC="$ROOT/scripts/dc2nc.sh"
NC="$ROOT/bin/nickel-compose"

rm -rf out
mkdir -p out

# --- helpers ---

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

  it "dc2nc: picked stdin list produces equivalent output" && {
    # The original shape: pipe a hand-curated list of fragments
    # through dc2nc.sh, render the resulting config.ncl, diff
    # against the golden.
    config="$ROOT/examples/dummy-project/out/dc2nc-config.ncl"
    (
      cd "$ROOT/examples/dummy-project"
      printf '%s\n' base.yml services/web.yml services/db.yml overlays/dev.yml \
        | "$DC2NC" --pick base.yml --pick services/web.yml \
                   --pick services/db.yml --pick overlays/dev.yml \
        > out/dc2nc-config.ncl
    )
    should_succeed
    # Nickel resolves imports relative to the importing file's
    # directory, so symlink the file to the project root for the
    # duration of the render — same trick the use path uses.
    config_at="$ROOT/examples/dummy-project/dc2nc-config.ncl"
    cp "$config" "$config_at"
    "$TO_WRAPPER" --in "$config_at" \
      --out "$ROOT/tests/out/dc2nc.yaml" >/dev/null
    should_succeed
    expect_no_diff_no_xsource "out/dc2nc.yaml" "out/dummy/compose.yaml"
    rm -f "out/dc2nc.yaml" "$config" "$config_at"
  }

  it "dc2nc: --find-all runs find itself" && {
    # --find-all means dc2nc.sh discovers fragments via `find`
    # rather than reading from stdin. Output must be valid Nickel
    # and uncomment only the picked fragments.
    (
      cd "$ROOT/examples/dummy-project"
      "$DC2NC" --find-all \
        --pick base.yml --pick services/web.yml \
        --pick services/db.yml --pick overlays/dev.yml \
        > "$ROOT/tests/out/dc2nc-findall.ncl"
    )
    should_succeed
    # All four picks present, uncommented.
    if grep -q '^  import "./base.yml",' out/dc2nc-findall.ncl \
       && grep -q '^  import "./services/web.yml",' out/dc2nc-findall.ncl \
       && grep -q '^  import "./services/db.yml",' out/dc2nc-findall.ncl \
       && grep -q '^  import "./overlays/dev.yml",' out/dc2nc-findall.ncl; then
      true
    else
      echo "expected all picks uncommented in:" >&2
      cat out/dc2nc-findall.ncl >&2
      false
    fi
    should_succeed
    # Unpicked candidates (config*.ncl, base.ncl, services/*.ncl, etc.)
    # appear as commented examples.
    if grep -q '^  # import "./config.ncl",' out/dc2nc-findall.ncl \
       && grep -q '^  # import "./base.ncl",' out/dc2nc-findall.ncl; then
      true
    else
      echo "expected unpicked candidates commented:" >&2
      cat out/dc2nc-findall.ncl >&2
      false
    fi
    should_succeed
    rm -f out/dc2nc-findall.ncl
  }

  it "dc2nc: relative path matches across directories (no collision)" && {
    # Pick two distinct fragments whose basenames would otherwise
    # collide in a flat namespace. dc2nc.sh's relative-path match
    # means they're unambiguously different. No rendering needed —
    # just check the output shape.
    mkdir -p out/agent out/database
    cat > "out/agent/base.yml" <<'EOF'
services:
  agent:
    image: "agent:1"
EOF
    cat > "out/database/base.yml" <<'EOF'
services:
  database:
    image: "postgres:16"
EOF
    (
      cd out
      "$DC2NC" --pick agent/base.yml --pick database/base.yml \
        > dc2nc-paths.ncl
    )
    should_succeed
    # Both imports uncommented.
    if grep -q '^  import "./agent/base.yml",' out/dc2nc-paths.ncl \
       && grep -q '^  import "./database/base.yml",' out/dc2nc-paths.ncl; then
      true
    else
      echo "expected both imports uncommented in:" >&2
      cat out/dc2nc-paths.ncl >&2
      false
    fi
    should_succeed
    rm -rf out/agent out/database out/dc2nc-paths.ncl
  }

  it "dc2nc: unpicked candidates appear as commented examples" && {
    # When stdin lists more candidates than --pick selects, the
    # unpicked ones must appear commented in the output (so the
    # user can see what was available). No rendering needed —
    # we just check the output shape.
    (
      cd "$ROOT/examples/dummy-project"
      printf '%s\n' base.yml services/web.yml services/db.yml overlays/dev.yml \
        | "$DC2NC" --pick base.yml --pick services/web.yml \
        > "$ROOT/tests/out/dc2nc-partial.ncl"
    )
    should_succeed
    # base.yml and services/web.yml are live (uncommented).
    if grep -q '^  import "./base.yml",' out/dc2nc-partial.ncl \
       && grep -q '^  import "./services/web.yml",' out/dc2nc-partial.ncl; then
      true
    else
      echo "expected picked imports uncommented" >&2
      cat out/dc2nc-partial.ncl >&2
      false
    fi
    should_succeed
    # services/db.yml and overlays/dev.yml are commented.
    if grep -q '^  # import "./services/db.yml",' out/dc2nc-partial.ncl \
       && grep -q '^  # import "./overlays/dev.yml",' out/dc2nc-partial.ncl; then
      true
    else
      echo "expected unpicked imports commented" >&2
      cat out/dc2nc-partial.ncl >&2
      false
    fi
    should_succeed
    rm -f out/dc2nc-partial.ncl
  }

  it "dc2nc: errors when no --pick given" && {
    (
      cd "$ROOT/examples/dummy-project"
      "$DC2NC" 2>/dev/null
    )
    should_fail
  }

  it "use: bare invocation honours \$NICKEL_COMPOSE" && {
    # Mise/CD-hook case: bare `nickel-compose use` with
    # NICKEL_COMPOSE pointed at a config produces the same render.
    (
      cd "$ROOT/examples/dummy-project"
      rm -f compose.ncl compose.yaml
      NICKEL_COMPOSE="config.ncl" "$NC" use \
        --out "$(pwd)/compose.yaml" >/dev/null
    )
    should_succeed
    expect_no_diff_no_xsource \
      "$ROOT/examples/dummy-project/compose.yaml" \
      "out/dummy/compose.yaml"
    rm -f "$ROOT/examples/dummy-project/compose.ncl" \
          "$ROOT/examples/dummy-project/compose.yaml"
  }

  it "use: explicit config arg overrides \$NICKEL_COMPOSE" && {
    # Point NICKEL_COMPOSE at config_ncl.ncl (pure-Nickel form)
    # but pass config.ncl explicitly. The render must use
    # config.ncl (x-source confirms), not config_ncl.ncl.
    (
      cd "$ROOT/examples/dummy-project"
      rm -f compose.ncl compose.yaml
      NICKEL_COMPOSE="config_ncl.ncl" "$NC" use config.ncl \
        --out "$(pwd)/compose.yaml" >/dev/null
    )
    should_succeed
    if [[ ! -f "$ROOT/examples/dummy-project/compose.ncl" ]]; then
      echo "compose.ncl was not written" >&2
      false
    fi
    should_succeed
    if grep -q '^x-source: config\.ncl$' \
         "$ROOT/examples/dummy-project/compose.yaml"; then
      true
    else
      echo "x-source did not reflect explicit config.ncl:" >&2
      grep '^x-source:' "$ROOT/examples/dummy-project/compose.yaml" >&2
      false
    fi
    should_succeed
    rm -f "$ROOT/examples/dummy-project/compose.ncl" \
          "$ROOT/examples/dummy-project/compose.yaml"
  }

  it "use: no arg and no NICKEL_COMPOSE defaults to ./config.ncl" && {
    # No NICKEL_COMPOSE, no explicit arg — falls back to the
    # cwd's config.ncl.
    (
      cd "$ROOT/examples/dummy-project"
      unset NICKEL_COMPOSE
      rm -f compose.ncl compose.yaml
      "$NC" use --out "$(pwd)/compose.yaml" >/dev/null
    )
    should_succeed
    expect_no_diff_no_xsource \
      "$ROOT/examples/dummy-project/compose.yaml" \
      "out/dummy/compose.yaml"
    rm -f "$ROOT/examples/dummy-project/compose.ncl" \
          "$ROOT/examples/dummy-project/compose.yaml"
  }

  it "two-step flow: compose.ncl is canonical and importable" && {
    # The .ncl is the source of truth: it must be a valid Nickel
    # file that, when imported, exposes the merged record. The
    # .yaml is a one-way projection of the same record.
    "$TO_WRAPPER" --in "$ROOT/examples/dummy-project/config.ncl" \
      --out "out/twostep.yaml" >/dev/null
    should_succeed

    ncl_at="out/twostep.ncl"
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
          "out/check-ncl.ncl" "out/check-ncl.json"
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
