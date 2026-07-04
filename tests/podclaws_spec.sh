#!/usr/bin/env bash
# tests/podclaws_spec.sh — bash-spec 2.1 tests for the patterns
# that real-world fragments (podclaws and similar) exercise:
#
#   - ${VAR} interpolation in build contexts, ports, env vars
#   - bind mounts (./relative, /abs, ${VAR}) — synthesis must skip
#   - short-form volume references (no colon)
#   - env_file as object form (record)
#   - command as array
#   - array concat across multiple array_fields (env, cap_add, etc.)
#
# Uses tests/fixtures/podclaws-patterns/ — fully self-contained,
# no dependency on /code/podclaws/. The original podclaws
# integration check is now opt-in via INIT_PODCLAWS=1.

cd "$(dirname "$0")"

. ./lib/bash-spec+file+jq.sh

ROOT="$(cd .. && pwd)"
FIXTURE="$ROOT/tests/fixtures/podclaws-patterns/config.ncl"

rm -rf out
mkdir -p out

describe "real-world fragment patterns" && {

  it "renders fixture to YAML without error" && {
    run nickel export --format yaml "$FIXTURE" | sed -n '2,$p' > "out/compose.yml"
    should_succeed
  }

  it "renders fixture to JSON without error" && {
    run nickel export --format json "$FIXTURE" > "out/compose.json"
    should_succeed
  }

  it "preserves \${VAR} interpolation in build context" && {
    expect_jq "out/compose.json" '.services.app.build.context' to_match '\$\{APP_DIR\}'
  }

  it "preserves \${VAR:-default} interpolation in ports" && {
    expect_jq "out/compose.json" '.services.app.ports[0]' to_match '\$\{APP_PORT:-8080\}:8080'
  }

  it "preserves \${VAR:?error} interpolation in environment" && {
    expect_jq "out/compose.json" '.services.app.environment[]' to_match 'REQUIRED_TOKEN=\$\{REQUIRED_TOKEN:'
  }

  it "preserves env_file as object form (record)" && {
    expect_jq "out/compose.json" '.services.app.env_file[0].path' to_be ".env"
    expect_jq "out/compose.json" '.services.app.env_file[0].required' to_be "false"
  }

  it "preserves command as array" && {
    expect_jq "out/compose.json" '.services.app.command[0]' to_be "/bin/app"
  }

  it "skips bind mounts (./relative) from synthesis" && {
    # Bind mount should appear in service.volumes, NOT be promoted
    # to a top-level named volume declaration.
    expect_jq "out/compose.json" '.services.app.volumes[]' to_match 'relative/dir'
    expect_jq "out/compose.json" '.volumes | has("relative")' to_be "false"
    expect_jq "out/compose.json" '.volumes | has("./relative")' to_be "false"
  }

  it "skips bind mounts (/abs) from synthesis" && {
    expect_jq "out/compose.json" '.services.app.volumes[]' to_match '/abs/path'
    expect_jq "out/compose.json" '.volumes | has("/abs/path")' to_be "false"
  }

  it "skips bind mounts (\${VAR}) from synthesis" && {
    expect_jq "out/compose.json" '.services.app.volumes[]' to_match '\$\{APP_DIR\}/skills'
    expect_jq "out/compose.json" '.volumes | has("${APP_DIR}")' to_be "false"
  }

  it "synthesizes short-form named volume reference" && {
    # volumes: ["shared-cache"] (no colon) → synthesized as
    # volumes: { shared-cache = null }
    expect_jq "out/compose.json" '.volumes | has("shared-cache")' to_be "true"
  }

  it "synthesizes named volume referenced by multiple services" && {
    # Both app and cache reference cache-data. Union of references
    # produces a single top-level declaration.
    expect_jq "out/compose.json" '.volumes | has("cache-data")' to_be "true"
  }

  it "concatenates environment arrays across fragments" && {
    # app.environment has entries from base + overlay, in order.
    expect_jq "out/compose.json" '.services.app.environment | length' to_be "5"
    # OVERLAY_VAR=from-overlay comes from overlay (later fragment),
    # and APP_DATA_DIR from base survives.
    expect_jq "out/compose.json" '.services.app.environment[]' to_match 'APP_DATA_DIR='
    expect_jq "out/compose.json" '.services.app.environment[]' to_match 'OVERLAY_VAR=from-overlay'
  }

  it "preserves top-level networks from base fragment" && {
    expect_jq "out/compose.json" '.networks.default.driver' to_be "bridge"
  }

  it "validates through podman-compose" && {
    if command -v podman-compose >/dev/null 2>&1; then
      REQUIRED_TOKEN=x APP_DIR=/app APP_PORT=8080 \
        podman-compose -f "out/compose.yml" config >/dev/null
      should_succeed
    else
      echo "(skipped — podman-compose not installed)"
      true
    fi
  }
}

# Optional: run the original /code/podclaws/ integration check if
# the host has it checked out. Off by default — useful for local
# developers who want the full integration check.
if [[ "${INIT_PODCLAWS:-false}" == "true" ]] && [[ -f "/code/podclaws/compose.yml" ]]; then
  describe "podclaws integration (opt-in)" && {
    it "renders podclaws example" && {
      run nickel export --format yaml "$ROOT/examples/podclaws/config.ncl" \
        | sed -n '2,$p' > "out/podclaws-compose.yml"
      should_succeed
    }

    it "validates through podman-compose" && {
      GOCLAW_GATEWAY_TOKEN=test podman-compose -f "out/podclaws-compose.yml" config >/dev/null
      should_succeed
    }
  }
fi