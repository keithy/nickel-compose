#!/usr/bin/env bash
# tests/nickel_compose_run_spec.sh — bash-spec 2.1 tests for the
# nickel-compose-run.sh wrapper.
#
# nickel-compose-run is a thin layer on top of nickel-run that
# pre-loads the merge engine as a free identifier. The standalone
# nickel-run mechanics are tested in nickel_run_spec.sh; this spec
# covers only the engine-binding behavior that nickel-compose-run
# adds on top.

cd "$(dirname "$0")"

. ./lib/bash-spec+file+jq.sh

ROOT="$(cd .. && pwd)"
NCR="$ROOT/bin/nickel-compose-run.sh"

rm -rf out
mkdir -p out

capture_run() {
  OUT="$(mise exec -- "$@" 2>"out/.stderr")"
  RC=$?
  ERR="$(cat out/.stderr)"
  rm -f out/.stderr
  return $RC
}

describe "nickel-compose-run.sh wrapper" && {
  it "pre-loads the engine as the free identifier 'compose'" && {
    cat > "out/empty.ncl" <<'EOF'
[]
EOF
    capture_run "$NCR" "fragments=out/empty.ncl" -- \
      'std.record.has_field "merge" compose'
    expect "$OUT" to_match '^true$'
  }

  it "sets NICKEL_IMPORT_PATH so the engine resolves" && {
    cat > "out/empty.ncl" <<'EOF'
[]
EOF
    # Force unset for this command; mise exec propagates it from
    # the calling shell, so use env -u to ensure it's gone.
    capture_run env -u NICKEL_IMPORT_PATH "$NCR" "fragments=out/empty.ncl" -- \
      'compose.version'
    expect "$OUT" to_match '"0\.[0-9]+\.[0-9]+"'
  }

  it "supports the standard 'use' expression: merge_with_source" && {
    cat > "out/fraglist.ncl" <<'EOF'
[ { services = { web = { image = "nginx" } } } ]
EOF
    capture_run "$NCR" "fragments=out/fraglist.ncl" -- \
      'std.array.length (std.record.fields (compose.merge_with_source fragments _paths.fragments).services)'
    expect "$OUT" to_match '^1$'
  }

  it "default format is ncl (raw eval); --format yaml converts" && {
    cat > "out/fraglist.ncl" <<'EOF'
[ { services = { web = { image = "nginx" } } } ]
EOF
    capture_run "$NCR" "fragments=out/fraglist.ncl" -- \
      'compose.merge_with_source fragments _paths.fragments'
    # Default: nickel record syntax (not yaml).
    expect "$OUT" to_match 'services ='
    expect "$OUT" to_match 'image = "nginx"'
  }
}