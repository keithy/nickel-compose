#!/usr/bin/env bash
# tests/merge_spec.sh — bash-spec 2.1 tests for the nickel-compose merge engine.
#
# Renders tests/merge.ncl to JSON, reads values with jq into bash
# variables, then asserts with bash-spec matchers.

. "$(dirname "$0")/lib/bash-spec.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Wrapper to invoke nickel. Uses mise exec if available.
run_nickel() {
  if command -v mise >/dev/null 2>&1; then
    mise exec -- nickel "$@"
  else
    nickel "$@"
  fi
}

OUT="$SCRIPT_DIR/.out.json"
run_nickel export --format json "$ROOT/tests/merge.ncl" > "$OUT"

# Read a JSON value into the bash variable named by $1.
# Defaults to $OUT; pass a third arg to read a different file.
read_jq() {
  local _name="$1" _expr="$2" _file="${3:-$OUT}"
  local _val
  _val=$(jq -r "$_expr" "$_file")
  printf -v "$_name" '%s' "$_val"
}

# Read a JSON array as a bash array named by $1.
read_jq_array() {
  local _name="$1" _expr="$2"
  mapfile -t "$_name" < <(jq -r "$_expr" "$OUT")
}

describe "nickel-compose merge engine" && {

  context "typecheck" && {
    it "lib/merge.ncl typechecks" && {
      run_nickel typecheck "$ROOT/lib/merge.ncl"
      should_succeed
    }

    it "tests/merge.ncl typechecks" && {
      run_nickel typecheck "$ROOT/tests/merge.ncl"
      should_succeed
    }
  }

  context "service field preservation" && {
    it "image is preserved from base" && {
      read_jq IMAGE '.services.web.image'
      expect "$IMAGE" to_be "nginx:1.27"
    }

    it "image is non-empty (not overwritten by absent overlay field)" && {
      read_jq IMAGE '.services.web.image'
      expect "$IMAGE" not to_be ""
    }
  }

  context "array concat" && {
    it "environment arrays are concatenated (length = 2)" && {
      read_jq LEN '.services.web.environment | length'
      expect "$LEN" to_be "2"
    }

    it "environment contains both FOO=1 and BAR=2" && {
      read_jq_array ENV '.services.web.environment[]'
      expect_array ENV to_contain "FOO=1"
      expect_array ENV to_contain "BAR=2"
    }

    it "environment order is base then overlay" && {
      read_jq E0 '.services.web.environment[0]'
      read_jq E1 '.services.web.environment[1]'
      expect "$E0" to_be "FOO=1"
      expect "$E1" to_be "BAR=2"
    }

    it "volume arrays are concatenated (length = 2)" && {
      read_jq LEN '.services.web.volumes | length'
      expect "$LEN" to_be "2"
    }

    it "volumes contain both base and overlay entries" && {
      read_jq_array VOLS '.services.web.volumes[]'
      expect_array VOLS to_contain "data:/var/lib/data"
      expect_array VOLS to_contain "/code:/code"
    }
  }

  context "default fill" && {
    it "networks defaults to [default]" && {
      read_jq NET '.services.web.networks[0]'
      expect "$NET" to_be "default"
    }

    it "restart defaults to unless-stopped" && {
      read_jq RESTART '.services.web.restart'
      expect "$RESTART" to_be "unless-stopped"
    }

    it "init defaults to false" && {
      read_jq INIT '.services.web.init'
      expect "$INIT" to_be "false"
    }
  }

  context "top-level union" && {
    it "named volume 'data' key exists from base" && {
      read_jq HAS_DATA '.volumes | has("data")'
      expect "$HAS_DATA" to_be "true"
    }
  }

  context "overlay overrides default" && {
    it "overlay networks wins over default [default]" && {
      cat > "$SCRIPT_DIR/.override.ncl" <<'EOF'
let build = import "../lib/merge.ncl" in
let base = { services = { web = { image = "x" } } } in
let overlay = { services = { web = { networks = ["other"] } } } in
build [base, overlay]
EOF
      run_nickel export --format json "$SCRIPT_DIR/.override.ncl" > "$SCRIPT_DIR/.override.json"
      NET=$(jq -r '.services.web.networks[0]' "$SCRIPT_DIR/.override.json")
      expect "$NET" to_be "other"
      rm -f "$SCRIPT_DIR/.override.ncl" "$SCRIPT_DIR/.override.json"
    }
  }

  context "end-to-end with dummy-project example" && {
    # The dummy project is self-contained (its own YAML fragments).
    # This is the CI-friendly end-to-end check that doesn't depend
    # on /code/podclaws paths.
    DUMMY="$ROOT/examples/dummy-project/config.ncl"
    DUMMY_OUT="$SCRIPT_DIR/.dummy.yml"
    DUMMY_JSON="$SCRIPT_DIR/.dummy.json"

    it "renders without error" && {
      run_nickel export --format yaml "$DUMMY" | sed -n '2,$p' > "$DUMMY_OUT"
      run_nickel export --format json "$DUMMY" > "$DUMMY_JSON"
      should_succeed
    }

    it "output has all three services" && {
      HAS_WEB=$(jq -r '.services | has("web")' "$DUMMY_JSON")
      HAS_DB=$(jq -r '.services | has("db")' "$DUMMY_JSON")
      HAS_REDIS=$(jq -r '.services | has("redis")' "$DUMMY_JSON")
      expect "$HAS_WEB" to_be "true"
      expect "$HAS_DB" to_be "true"
      expect "$HAS_REDIS" to_be "true"
    }

    it "db port from dev overlay is merged" && {
      PORT=$(jq -r '.services.db.ports[0]' "$DUMMY_JSON")
      expect "$PORT" to_be "5432:5432"
    }

    it "web env from dev overlay is appended" && {
      REDIS_HOST=$(jq -r '.services.web.environment[] | select(test("REDIS_HOST"))' "$DUMMY_JSON")
      expect "$REDIS_HOST" to_match "REDIS_HOST=redis"
    }

    it "validates through podman-compose" && {
      if command -v podman-compose >/dev/null 2>&1; then
        podman-compose -f "$DUMMY_OUT" config >/dev/null
        should_succeed
      else
        echo "(skipped)"
        true
      fi
    }

    it "named volumes union across fragments" && {
      HAS_WEB_DATA=$(jq -r '.volumes | has("web-data")' "$DUMMY_JSON")
      HAS_DB_DATA=$(jq -r '.volumes | has("db-data")' "$DUMMY_JSON")
      expect "$HAS_WEB_DATA" to_be "true"
      expect "$HAS_DB_DATA" to_be "true"
    }
  }

  context "end-to-end with podclaws example (optional)" && {
    # Skipped in CI — depends on /code/podclaws YAML paths.
    EXAMPLE="$ROOT/examples/podclaws/config.ncl"
    EXAMPLE_OUT="$SCRIPT_DIR/.example.yml"

    it "renders without error" && {
      if [[ -f "$EXAMPLE" ]] && [[ -f "/code/podclaws/compose.yml" ]]; then
        run_nickel export --format yaml "$EXAMPLE" | sed -n '2,$p' > "$EXAMPLE_OUT"
        should_succeed
      else
        echo "(skipped — no /code/podclaws/compose.yml)"
        true
      fi
    }

    it "validates through podman-compose" && {
      if command -v podman-compose >/dev/null 2>&1 && [[ -f "$EXAMPLE_OUT" ]]; then
        GOCLAW_GATEWAY_TOKEN=test podman-compose -f "$EXAMPLE_OUT" config >/dev/null
        should_succeed
      else
        echo "(skipped)"
        true
      fi
    }
  }
}