#!/usr/bin/env bash
# tests/run.sh — smoke test the merge engine.
#
# Renders tests/merge.ncl to YAML and checks expected values.
# Exits 0 on success, 1 on any mismatch.
#
# Requires: nickel, jq.

set -euo pipefail

SCRIPT="${BASH_SOURCE[0]}"
TESTS_DIR="$(cd "$(dirname "$SCRIPT")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"

if command -v mise >/dev/null 2>&1; then
  NICKEL="mise exec -- nickel"
else
  NICKEL="nickel"
fi

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

pass() {
  echo "PASS: $1"
}

# 1. typecheck the library and tests
$NICKEL typecheck "$ROOT/lib/merge.ncl" || fail "lib/merge.ncl typecheck"
pass "lib/merge.ncl typechecks"

$NICKEL typecheck "$ROOT/tests/merge.ncl" || fail "tests/merge.ncl typecheck"
pass "tests/merge.ncl typechecks"

# 2. render the test fixture to JSON (jq-friendly)
OUT="$TESTS_DIR/.out.json"
$NICKEL export --format json "$ROOT/tests/merge.ncl" > "$OUT"
pass "rendered $OUT"

# 3. check expected values via jq
command -v jq >/dev/null || fail "jq not found"

[[ "$(jq -r '.services.web.image' "$OUT")" == "nginx:1.27" ]] \
  || fail "expected web.image=nginx:1.27"
pass "image preserved"

[[ "$(jq -r '.services.web.environment | length' "$OUT")" == "2" ]] \
  || fail "expected 2 env entries"
pass "environment concat"

[[ "$(jq -r '.services.web.environment[0]' "$OUT")" == "FOO=1" ]] \
  || fail "expected env[0]=FOO=1"
[[ "$(jq -r '.services.web.environment[1]' "$OUT")" == "BAR=2" ]] \
  || fail "expected env[1]=BAR=2"
pass "environment order preserved (base, then overlay)"

[[ "$(jq -r '.services.web.volumes | length' "$OUT")" == "2" ]] \
  || fail "expected 2 volume entries"
pass "volumes concat"

[[ "$(jq -r '.services.web.networks[0]' "$OUT")" == "default" ]] \
  || fail "expected default network"
pass "defaults filled"

[[ "$(jq -r '.services.web.restart' "$OUT")" == "unless-stopped" ]] \
  || fail "expected restart=unless-stopped"
pass "restart default filled"

# 4. run the example end-to-end if podclaws YAML is present
EXAMPLE="$ROOT/examples/podclaws/config.ncl"
if [[ -f "$EXAMPLE" ]] && [[ -f "/code/podclaws/compose.yml" ]]; then
  EXAMPLE_OUT="$TESTS_DIR/.example.yml"
  $NICKEL export --format yaml "$EXAMPLE" | sed -n '2,$p' > "$EXAMPLE_OUT" \
    || fail "example export failed"
  if command -v podman-compose >/dev/null 2>&1; then
    GOCLAW_GATEWAY_TOKEN=test podman-compose -f "$EXAMPLE_OUT" config >/dev/null \
      || fail "podman-compose validation failed"
    pass "podclaws example round-trips through podman-compose"
  else
    echo "SKIP: podman-compose not installed"
  fi
else
  echo "SKIP: podclaws example (no /code/podclaws/compose.yml)"
fi

echo "ALL TESTS PASSED"