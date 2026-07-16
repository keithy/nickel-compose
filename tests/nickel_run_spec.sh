#!/usr/bin/env bash
# tests/nickel_run_spec.sh — bash-spec 2.1 tests for the standalone
# nickel-run.sh tool and the nickel-compose-run.sh wrapper.
#
# These tests exercise the wrapper mechanics in isolation, not
# the merge engine. The engine is tested by merge_spec / schema_spec.

cd "$(dirname "$0")"

. ./lib/bash-spec+file+jq.sh

ROOT="$(cd .. && pwd)"
NR="$ROOT/scripts/nickel-run.sh"
NCR="$ROOT/scripts/nickel-compose-run.sh"

rm -rf out
mkdir -p out

# Helper: run a command, capturing stdout to OUT and stderr to ERR.
# Returns the exit code in $RC. Used in place of `run` so we can
# match against captured output.
capture_run() {
  OUT="$(mise exec -- "$@" 2>"out/.stderr")"
  RC=$?
  ERR="$(cat out/.stderr)"
  rm -f out/.stderr
  return $RC
}

describe "nickel-run.sh standalone" && {
  it "evaluates an expression against a single .ncl input" && {
    cat > "out/data.ncl" <<'EOF'
{ name = "alice", age = 30 }
EOF
    capture_run "$NR" "f=out/data.ncl" -- 'f.name'
    expect "$OUT" to_match '"alice"'
  }

  it "accepts .json input directly (no pre-conversion needed)" && {
    cat > "out/data.json" <<'EOF'
{ "name": "bob", "items": [1, 2, 3] }
EOF
    capture_run "$NR" "f=out/data.json" -- 'std.array.length f.items'
    expect "$OUT" to_match "^3$"
  }

  it "accepts .yml input directly" && {
    cat > "out/data.yml" <<'EOF'
name: carol
items:
  - one
  - two
  - three
EOF
    capture_run "$NR" "f=out/data.yml" -- 'std.array.length f.items'
    expect "$OUT" to_match "^3$"
  }

  it "exposes _paths.NAME for the input's absolute path" && {
    capture_run "$NR" "f=out/data.ncl" -- '_paths.f'
    expect "$OUT" to_match "/out/data.ncl"
  }

  it "underscore prefix lets a user input named 'paths' coexist with the _paths record" && {
    cat > "out/data.ncl" <<'EOF'
{ greeting = "hi" }
EOF
    capture_run "$NR" "paths=out/data.ncl" -- 'paths.greeting'
    expect "$OUT" to_match '"hi"'
    capture_run "$NR" "paths=out/data.ncl" -- '_paths.paths'
    expect "$OUT" to_match "/out/data.ncl"
  }

  it "supports multiple named inputs as free identifiers" && {
    cat > "out/list.ncl" <<'EOF'
[ "a", "b", "c" ]
EOF
    cat > "out/label.ncl" <<'EOF'
let l = fun x => "item: %{x}" in l
EOF
    capture_run "$NR" "l=out/list.ncl" "f=out/label.ncl" -- \
      'f (std.array.at 1 l)'
    expect "$OUT" to_match '"item: b"'
  }

  it "lets you reference the input by the user-chosen name" && {
    cat > "out/cfg.ncl" <<'EOF'
{ services = { web = { image = "nginx" } } }
EOF
    capture_run "$NR" "config=out/cfg.ncl" -- 'config.services.web.image'
    expect "$OUT" to_match '"nginx"'
  }

  it "--format yaml pipes through nickel export" && {
    cat > "out/data.ncl" <<'EOF'
{ name = "alice", port = 8080 }
EOF
    capture_run "$NR" --format yaml "f=out/data.ncl" -- 'f'
    expect "$OUT" to_match "name: alice"
    expect "$OUT" to_match "port: 8080"
  }

  it "--format json produces valid JSON" && {
    cat > "out/data.ncl" <<'EOF'
{ name = "alice", port = 8080 }
EOF
    capture_run "$NR" --format json "f=out/data.ncl" -- 'f'
    expect "$OUT" to_match '"name"'
    expect "$OUT" to_match '"alice"'
    expect "$OUT" to_match '8080'
  }

  it "--format toml works" && {
    cat > "out/data.ncl" <<'EOF'
{ name = "alice" }
EOF
    capture_run "$NR" --format toml "f=out/data.ncl" -- 'f'
    expect "$OUT" to_match 'name = "alice"'
  }

  it "--out writes to a file and suppresses stdout" && {
    cat > "out/data.ncl" <<'EOF'
{ x = 42 }
EOF
    capture_run "$NR" --out "out/written.json" --format json "f=out/data.ncl" -- 'f'
    expect "$OUT" to_match '^$'
    expect "out/written.json" to_exist
    capture_run cat "out/written.json"
    expect "$OUT" to_match '"x"'
    expect "$OUT" to_match '42'
  }

  it "--keep leaves the temp wrapper for inspection" && {
    cat > "out/data.ncl" <<'EOF'
{ x = 1 }
EOF
    capture_run "$NR" --keep "f=out/data.ncl" -- 'f'
    expect "$ERR" to_match "wrapper kept:"
  }

  it "errors when input file is missing" && {
    capture_run "$NR" "f=out/does-not-exist.ncl" -- 'f'
    should_fail
    expect "$ERR" to_match 'input not found'
  }

  it "errors when no -- is given" && {
    cat > "out/data.ncl" <<'EOF'
{ x = 1 }
EOF
    capture_run "$NR" "f=out/data.ncl" 'f'
    should_fail
    expect "$ERR" to_match "use -- before the expression"
  }

  it "errors when no NAME=PATH inputs are given" && {
    capture_run "$NR" -- '1 + 1'
    should_fail
    expect "$ERR" to_match 'no NAME=PATH inputs given'
  }

  it "errors on duplicate names" && {
    capture_run "$NR" "f=out/data.ncl" "f=out/data.ncl" -- 'f'
    should_fail
    expect "$ERR" to_match "duplicate name"
  }

  it "errors on malformed NAME=PATH" && {
    capture_run "$NR" "=no-name" -- '1'
    should_fail
    expect "$ERR" to_match "malformed NAME=PATH"
  }

  it "errors on unknown flag" && {
    capture_run "$NR" --bogus "f=out/data.ncl" -- 'f'
    should_fail
    expect "$ERR" to_match "unknown flag"
  }

  it "errors on unknown --format" && {
    cat > "out/data.ncl" <<'EOF'
{ x = 1 }
EOF
    capture_run "$NR" --format xml "f=out/data.ncl" -- 'f'
    should_fail
    expect "$ERR" to_match "unknown format"
  }

  it "rejects names with spaces (not valid Nickel identifiers)" && {
    cat > "out/data.ncl" <<'EOF'
{ x = 1 }
EOF
    capture_run "$NR" "f space=out/data.ncl" -- 'f'
    should_fail
    expect "$ERR" to_match "invalid name"
    expect "$ERR" to_match "A-Za-z_"
  }

  it "rejects names with hyphens (not valid Nickel identifiers)" && {
    cat > "out/data.ncl" <<'EOF'
{ x = 1 }
EOF
    capture_run "$NR" "f-name=out/data.ncl" -- 'f'
    should_fail
    expect "$ERR" to_match "invalid name"
  }

  it "accepts names with underscores and digits" && {
    cat > "out/data.ncl" <<'EOF'
{ x = 1 }
EOF
    capture_run "$NR" "f_2=out/data.ncl" -- 'f_2.x'
    expect "$OUT" to_match "^1$"
  }

  it "expands leading ~ in PATH" && {
    cat > "$HOME/nc-tilde-test.ncl" <<'EOF'
{ greeting = "hello" }
EOF
    capture_run "$NR" "f=~/nc-tilde-test.ncl" -- 'f.greeting'
    expect "$OUT" to_match '"hello"'
    # _paths.f should be the expanded absolute path.
    capture_run "$NR" "f=~/nc-tilde-test.ncl" -- '_paths.f'
    expect "$OUT" to_match "/nc-tilde-test.ncl"
    rm -f "$HOME/nc-tilde-test.ncl"
  }

  it "refuses to clobber an input via --out" && {
    cat > "out/data.ncl" <<'EOF'
{ x = 1 }
EOF
    capture_run "$NR" --out "out/data.ncl" "f=out/data.ncl" -- 'f'
    should_fail
    expect "$ERR" to_match "would clobber"
  }

  it "rejects paths containing double-quote (would break wrapper)" && {
    cat > "out/data.ncl" <<'EOF'
{ x = 1 }
EOF
    # The character is in the *path*, not in the file we point at.
    # Use a glob-style literal in the test that exercises the
    # check directly; the path doesn't have to exist for the
    # check to fire (we check before stat-ing).
    capture_run "$NR" 'f=out/has"quote.ncl' -- 'f'
    should_fail
    expect "$ERR" to_match "double-quote"
  }

  it "rejects paths containing backslash (would break wrapper)" && {
    capture_run "$NR" 'f=out/has\backslash.ncl' -- 'f'
    should_fail
    expect "$ERR" to_match "backslash"
  }

  it "automatically keeps the wrapper on nickel eval failure" && {
    cat > "out/data.ncl" <<'EOF'
{ x = 1 }
EOF
    capture_run "$NR" "f=out/data.ncl" -- 'f.nonexistent_field'
    should_fail
    # The wrapper path is printed so the user can inspect.
    expect "$ERR" to_match "wrapper kept for debugging:"
  }
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
    expect "$OUT" to_match '"0.2.0"'
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
