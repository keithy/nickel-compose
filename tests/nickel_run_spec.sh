#!/usr/bin/env bash
# tests/nickel_run_spec.sh — bash-spec 2.1 tests for the standalone
# nickel-run.sh tool.
#
# This spec is the conformance suite for the proposed native
# `nickel run` subcommand (see docs/nickel-run.md and
# nickel-lang/nickel#2636). It exercises the wrapper mechanics
# in isolation — no merge engine involvement.
#
# The engine-binding layer (nickel-compose-run) has its own spec:
# tests/nickel_compose_run_spec.sh.

cd "$(dirname "$0")"

. ./lib/bash-spec+file+jq.sh

ROOT="$(cd .. && pwd)"
NR="$ROOT/bin/nickel-run.sh"

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

  it "--format env emits dotenv-style KEY=VALUE per line" && {
    cat > "out/data.ncl" <<'EOF'
{ name = "alice", port = 8080 }
EOF
    capture_run "$NR" --format env "f=out/data.ncl" -- 'f'
    expect "$OUT" to_match 'name='
    expect "$OUT" to_match 'port='
    expect "$OUT" to_match '8080'
  }

  it "--format env JSON-encodes nested arrays" && {
    cat > "out/data.ncl" <<'EOF'
{ tags = [ "admin", "ops" ] }
EOF
    capture_run "$NR" --format env "f=out/data.ncl" -- 'f'
    expect "$OUT" to_match 'tags=\["admin","ops"\]'
  }

  it "--format bash emits sourceable bash syntax (record)" && {
    cat > "out/data.ncl" <<'EOF'
{ name = "alice", port = 8080 }
EOF
    capture_run "$NR" --format bash "f=out/data.ncl" -- 'f'
    expect "$OUT" to_match 'name=alice'
    expect "$OUT" to_match 'port=8080'
  }

  it "--format bash emits sourceable bash arrays" && {
    cat > "out/data.ncl" <<'EOF'
{ tags = [ "admin", "ops" ] }
EOF
    capture_run "$NR" --format bash "f=out/data.ncl" -- 'f'
    expect "$OUT" to_match 'tags=\(admin ops\)'
  }

  it "--format bash output is actually bash-sourceable" && {
    cat > "out/data.ncl" <<'EOF'
{ name = "alice", port = 8080 }
EOF
    capture_run "$NR" --format bash --out "out/sourced.sh" "f=out/data.ncl" -- 'f'
    # Source the file in a subshell and verify the variables
    # landed in the environment. If quoting is wrong, this fails
    # with an unset-variable or parse error.
    captured="$(bash -c 'set -e; source out/sourced.sh; echo "${name}:${port}"')"
    expect "$captured" to_be 'alice:8080'
  }

  it "--format bash quotes strings with spaces" && {
    cat > "out/data.ncl" <<'EOF'
{ greeting = "hello world" }
EOF
    capture_run "$NR" --format bash "f=out/data.ncl" -- 'f'
    expect "$OUT" to_match 'greeting="hello world"'
  }

  it "--raw rejects --format env" && {
    cat > "out/data.ncl" <<'EOF'
{ name = "alice" }
EOF
    capture_run "$NR" --format env --raw "f=out/data.ncl" -- 'f'
    should_fail
    expect "$ERR" to_match '--raw cannot be combined with --format env'
  }

  it "--raw rejects --format bash" && {
    cat > "out/data.ncl" <<'EOF'
{ name = "alice" }
EOF
    capture_run "$NR" --format bash --raw "f=out/data.ncl" -- 'f'
    should_fail
    expect "$ERR" to_match '--raw cannot be combined with --format bash'
  }

  it "--raw strips quotes from a scalar result (json)" && {
    cat > "out/data.ncl" <<'EOF'
{ name = "alice", port = 8080 }
EOF
    capture_run "$NR" --format json --raw "f=out/data.ncl" -- 'f.name'
    expect "$OUT" to_be 'alice'
    expect "$OUT" to_not_match '"'
  }

  it "--raw prints one element per line for an array of scalars" && {
    cat > "out/data.ncl" <<'EOF'
{ items = [ "alpha", "beta", "gamma" ] }
EOF
    capture_run "$NR" --format json --raw "f=out/data.ncl" -- 'f.items'
    expect "$OUT" to_be 'alpha
beta
gamma'
  }

  it "--raw leaves records unchanged (keys are required JSON)" && {
    cat > "out/data.ncl" <<'EOF'
{ services = { web = { image = "nginx" } } }
EOF
    capture_run "$NR" --format json --raw "f=out/data.ncl" -- 'f.services'
    expect "$OUT" to_match '"web"'
    expect "$OUT" to_match '"image"'
    expect "$OUT" to_match '"nginx"'
  }

  it "--raw works with --out" && {
    cat > "out/data.ncl" <<'EOF'
{ name = "alice" }
EOF
    capture_run "$NR" --format json --raw --out "out/raw-name.txt" "f=out/data.ncl" -- 'f.name'
    expect "$(cat out/raw-name.txt)" to_be 'alice'
  }

  it "--raw rejects --format yaml (jq -r only understands JSON)" && {
    cat > "out/data.ncl" <<'EOF'
{ name = "alice" }
EOF
    capture_run "$NR" --format yaml --raw "f=out/data.ncl" -- 'f.name'
    should_fail
    expect "$ERR" to_match '--raw requires --format json'
  }

  it "--raw rejects --format ncl (no export, no jq pipeline)" && {
    cat > "out/data.ncl" <<'EOF'
{ name = "alice" }
EOF
    capture_run "$NR" --raw "f=out/data.ncl" -- 'f.name'
    should_fail
    expect "$ERR" to_match '--raw requires --format json'
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
