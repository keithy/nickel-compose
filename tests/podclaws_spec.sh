#!/usr/bin/env bash
# tests/podclaws_spec.sh — bash-spec 2.1 end-to-end test for the
# examples/podclaws/ integration. Skipped when the host doesn't
# have /code/podclaws/ available (e.g. CI).
#
# Per bash-spec convention, the spec runs in its own directory.

cd "$(dirname "$0")"

. ./lib/bash-spec+file+jq.sh

ROOT="$(cd .. && pwd)"

EXAMPLE="$ROOT/examples/podclaws/config.ncl"

# Bail out cleanly if podclaws isn't checked out — every assertion
# would otherwise be "(skipped)" and the spec would look empty.
if [[ ! -f "$EXAMPLE" ]] || [[ ! -f "/code/podclaws/compose.yml" ]]; then
  echo "(skipped — no /code/podclaws/compose.yml)"
  exit 0
fi

rm -rf out
mkdir -p out

describe "podclaws example end-to-end" && {
  it "renders YAML without error" && {
    mkdir -p "out/podclaws"
    run nickel export --format yaml "$EXAMPLE" | sed -n '2,$p' > "out/podclaws/compose.yml"
    should_succeed
  }

  it "validates through podman-compose" && {
    if command -v podman-compose >/dev/null 2>&1; then
      GOCLAW_GATEWAY_TOKEN=test podman-compose -f "out/podclaws/compose.yml" config >/dev/null
      should_succeed
    else
      echo "(skipped)"
      true
    fi
  }
}

# Cleanup so subsequent runs start fresh (podclaws artifacts only
# exist locally, not in CI).
rm -rf "out/podclaws"