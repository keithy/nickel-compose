#!/usr/bin/env bash
# tests/merge_spec.sh — bash-spec 2.1 tests for the nickel-compose merge engine.
#
# Uses golden-file comparison: render outputs to tests/out/, compare
# against tests/expected/ snapshots. Set INIT=true to copy out/ over
# expected/ instead of comparing (used to update snapshots).
#
# Renders tests/merge.ncl and examples/dummy-project/config.ncl to
# JSON and YAML, then asserts with bash-spec matchers.

. "$(dirname "$0")/lib/bash-spec.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

OUT_DIR="$SCRIPT_DIR/out"
EXPECTED_DIR="$SCRIPT_DIR/expected"
INIT="${INIT:-false}"

# Wrapper to invoke nickel. Uses mise exec if available.
run_nickel() {
  if command -v mise >/dev/null 2>&1; then
    mise exec -- nickel "$@"
  else
    nickel "$@"
  fi
}

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# Read a JSON value into the bash variable named by $1.
# Defaults to the rendered merge.ncl output; pass a third arg to
# read a different file.
read_jq() {
  local _name="$1" _expr="$2" _file="${3:-$OUT_DIR/merge.json}"
  local _val
  _val=$(jq -r "$_expr" "$_file")
  printf -v "$_name" '%s' "$_val"
}

# Compare a generated file against its expected snapshot. When INIT=true,
# copy the generated file to the expected location instead.
assert_matches_expected() {
  local _generated="$1" _expected="$2"
  if [[ "$INIT" == "true" ]]; then
    mkdir -p "$(dirname "$_expected")"
    cp "$_generated" "$_expected"
    echo "      (init) wrote $_expected"
    return 0
  fi
  if [[ ! -f "$_expected" ]]; then
    echo "      MISSING expected file: $_expected"
    echo "      run with INIT=true to create it"
    return 1
  fi
  if diff -q "$_generated" "$_expected" >/dev/null 2>&1; then
    return 0
  else
    diff "$_generated" "$_expected" | head -20
    return 1
  fi
}

describe "nickel-compose merge engine" && {

  context "typecheck" && {
    it "lib/merge.ncl typechecks" && {
      run_nickel typecheck "$ROOT/lib/merge.ncl"
      should_succeed
    }

    it "examples/dummy-project/config.ncl typechecks" && {
      run_nickel typecheck "$ROOT/examples/dummy-project/config.ncl"
      should_succeed
    }
  }

  context "merge engine: synthetic fixture" && {
    FIXTURE="$ROOT/tests/merge.ncl"

    it "renders to JSON" && {
      run_nickel export --format json "$FIXTURE" > "$OUT_DIR/merge.json"
      should_succeed
    }

    it "JSON output matches expected snapshot" && {
      assert_matches_expected "$OUT_DIR/merge.json" "$EXPECTED_DIR/merge.json"
      should_succeed
    }

    it "service field preservation: image kept from base" && {
      read_jq IMAGE '.services.web.image'
      expect "$IMAGE" to_be "nginx:1.27"
    }

    it "array concat: environment has both entries" && {
      read_jq LEN '.services.web.environment | length'
      expect "$LEN" to_be "2"
      read_jq E0 '.services.web.environment[0]'
      read_jq E1 '.services.web.environment[1]'
      expect "$E0" to_be "FOO=1"
      expect "$E1" to_be "BAR=2"
    }

    it "array concat: volumes are concatenated" && {
      read_jq LEN '.services.web.volumes | length'
      expect "$LEN" to_be "2"
    }

    it "default fill: networks, restart, init" && {
      read_jq NET '.services.web.networks[0]'
      read_jq RESTART '.services.web.restart'
      read_jq INIT_FILL '.services.web.init'
      expect "$NET" to_be "default"
      expect "$RESTART" to_be "unless-stopped"
      expect "$INIT_FILL" to_be "false"
    }

    it "top-level union: named volume 'data' present" && {
      read_jq HAS_DATA '.volumes | has("data")'
      expect "$HAS_DATA" to_be "true"
    }
  }

  context "overlay behavior" && {
    it "overlay networks wins over default [default]" && {
      cat > "$OUT_DIR/.override.ncl" <<EOF
let build = import "$ROOT/lib/merge.ncl" in
let base = { services = { web = { image = "x" } } } in
let overlay = { services = { web = { networks = ["other"] } } } in
build [base, overlay]
EOF
      run_nickel export --format json "$OUT_DIR/.override.ncl" > "$OUT_DIR/.override.json"
      NET=$(jq -r '.services.web.networks[0]' "$OUT_DIR/.override.json")
      expect "$NET" to_be "other"
      rm -f "$OUT_DIR/.override.ncl" "$OUT_DIR/.override.json"
    }
  }

  context "end-to-end with dummy-project example" && {
    DUMMY="$ROOT/examples/dummy-project/config.ncl"

    it "renders YAML without error" && {
      mkdir -p "$OUT_DIR/dummy"
      run_nickel export --format yaml "$DUMMY" | sed -n '2,$p' > "$OUT_DIR/dummy/compose.yml"
      should_succeed
    }

    it "renders JSON without error" && {
      run_nickel export --format json "$DUMMY" > "$OUT_DIR/dummy/combined.json"
      should_succeed
    }

    it "YAML output matches expected snapshot" && {
      assert_matches_expected "$OUT_DIR/dummy/compose.yml" "$EXPECTED_DIR/dummy/compose.yml"
      should_succeed
    }

    it "all three services present (web, db, redis)" && {
      HAS_WEB=$(jq -r '.services | has("web")' "$OUT_DIR/dummy/combined.json")
      HAS_DB=$(jq -r '.services | has("db")' "$OUT_DIR/dummy/combined.json")
      HAS_REDIS=$(jq -r '.services | has("redis")' "$OUT_DIR/dummy/combined.json")
      expect "$HAS_WEB" to_be "true"
      expect "$HAS_DB" to_be "true"
      expect "$HAS_REDIS" to_be "true"
    }

    it "db port from dev overlay is merged" && {
      PORT=$(jq -r '.services.db.ports[0]' "$OUT_DIR/dummy/combined.json")
      expect "$PORT" to_be "5432:5432"
    }

    it "web env from dev overlay is appended" && {
      REDIS_HOST=$(jq -r '.services.web.environment[] | select(test("REDIS_HOST"))' "$OUT_DIR/dummy/combined.json")
      expect "$REDIS_HOST" to_match "REDIS_HOST=redis"
    }

    it "named volumes union (web-data, db-data)" && {
      HAS_WEB_DATA=$(jq -r '.volumes | has("web-data")' "$OUT_DIR/dummy/combined.json")
      HAS_DB_DATA=$(jq -r '.volumes | has("db-data")' "$OUT_DIR/dummy/combined.json")
      expect "$HAS_WEB_DATA" to_be "true"
      expect "$HAS_DB_DATA" to_be "true"
    }

    it "validates through podman-compose" && {
      if command -v podman-compose >/dev/null 2>&1; then
        podman-compose -f "$OUT_DIR/dummy/compose.yml" config >/dev/null
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
        WRAPPER_OUT="$OUT_DIR/wrapper-output.yml"
        (
          cd "$ROOT/examples/dummy-project"
          COMPOSE_FRAGMENTS="base.yml:services/web.yml:services/db.yml:overlays/dev.yml" \
            "$WRAPPER" --out "$WRAPPER_OUT" >/dev/null
        )
        should_succeed

        if ! diff -q "$WRAPPER_OUT" "$OUT_DIR/dummy/compose.yml" >/dev/null 2>&1; then
          diff "$WRAPPER_OUT" "$OUT_DIR/dummy/compose.yml" | head -20
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
        WRAPPER_OUT="$OUT_DIR/wrapper-stage0.yml"
        (
          cd "$ROOT/examples/dummy-project"
          COMPOSE_FILE="base.yml:services/web.yml:services/db.yml:overlays/dev.yml" \
            NICKEL_COMPOSE='$COMPOSE_FILE' \
            "$WRAPPER" --out "$WRAPPER_OUT" >/dev/null
        )
        should_succeed

        if ! diff -q "$WRAPPER_OUT" "$OUT_DIR/dummy/compose.yml" >/dev/null 2>&1; then
          diff "$WRAPPER_OUT" "$OUT_DIR/dummy/compose.yml" | head -20
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
        WRAPPER_OUT="$OUT_DIR/wrapper-stage1.yml"
        (
          cd "$ROOT/examples/dummy-project"
          COMPOSE_SERVICES="services/web.yml:services/db.yml" \
            COMPOSE_OVERLAYS="overlays/dev.yml" \
            COMPOSE_FILE="base.yml" \
            NICKEL_COMPOSE='$COMPOSE_SERVICES:$COMPOSE_OVERLAYS:$COMPOSE_FILE' \
            "$WRAPPER" --out "$WRAPPER_OUT" >/dev/null
        )
        should_succeed

        if ! diff -q "$WRAPPER_OUT" "$OUT_DIR/dummy/compose.yml" >/dev/null 2>&1; then
          diff "$WRAPPER_OUT" "$OUT_DIR/dummy/compose.yml" | head -20
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
  }

  context "end-to-end with podclaws example (optional)" && {
    # Skipped in CI — depends on /code/podclaws YAML paths.
    EXAMPLE="$ROOT/examples/podclaws/config.ncl"

    it "renders YAML without error" && {
      if [[ -f "$EXAMPLE" ]] && [[ -f "/code/podclaws/compose.yml" ]]; then
        mkdir -p "$OUT_DIR/podclaws"
        run_nickel export --format yaml "$EXAMPLE" | sed -n '2,$p' > "$OUT_DIR/podclaws/compose.yml"
        should_succeed
      else
        echo "(skipped — no /code/podclaws/compose.yml)"
        true
      fi
    }

    it "validates through podman-compose" && {
      if command -v podman-compose >/dev/null 2>&1 && [[ -f "$OUT_DIR/podclaws/compose.yml" ]]; then
        GOCLAW_GATEWAY_TOKEN=test podman-compose -f "$OUT_DIR/podclaws/compose.yml" config >/dev/null
        should_succeed
      else
        echo "(skipped)"
        true
      fi
    }

    # Cleanup: only present locally (not CI). Remove so subsequent
    # runs start fresh.
    rm -rf "$OUT_DIR/podclaws"
  }
}