#!/usr/bin/env bash
# tests/lib/bash-spec+file+jq.sh
#
# Extension of bash-spec 2.1 with file and jq helpers used by
# nickel-compose specs. Sources bash-spec.sh so callers get the
# matchers (expect, should_succeed, should_fail, describe, context,
# it) plus:
#
#   run <cmd> <args...>              Invoke <cmd>, via `mise exec` if available.
#   expect_no_diff <gen> <expected>
#                                    Diff gen vs expected; when INIT=true, copy
#                                    gen over expected instead (snapshot regen).
#   expect_no_diff_no_xsource <gen> <expected>
#                                    Like expect_no_diff, but strips the
#                                    `x-source:` line from both files first.
#                                    The x-source field is provenance metadata
#                                    (the literal path the user typed) and
#                                    varies per call site, so it can't be part
#                                    of a golden comparison.
#   expect_podman_compose <yaml>     Run `podman-compose -f <yaml> config` and
#                                    assert success. Skips silently if
#                                    podman-compose isn't on PATH.
#   expect_jq <file> <expr> to_be <value>
#                                    Like `expect <file> to_exist`, but jq-queries
#                                    the file: runs `jq -r <expr> <file>` and
#                                    compares to <value>.
#                                    Works with: to_be, to_match, and `not` (negation).
#                                    Does NOT work with to_be_true — it's a command-
#                                    runner matcher, not a value matcher.

# Resolve our own directory so the source path is robust regardless of
# where the calling spec lives.
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$_LIB_DIR/bash-spec.sh"

# Wrapper to invoke a command. Uses mise exec if available so tools
# pinned in mise/config.toml (nickel, jq) resolve to the right version.
# Usage: run <cmd> <args...>
run() {
  if command -v mise >/dev/null 2>&1; then
    mise exec -- "$@"
  else
    "$@"
  fi
}

# expect_no_diff: assert that <generated> and <expected> files are
# byte-identical. When INIT=true, copy generated over expected
# instead (snapshot regeneration). Reports through bash-spec's
# _pass_/_actual_/_expected_ and _negation_check_ so the pass/fail
# tally updates and no `should_succeed` wrapper is needed.
#
# Negation via `not expect_no_diff ...` is not really meaningful —
# "files differ" is just the inverse of this matcher, and conflates
# with INIT-mode (which forces equality). Don't use `not` here.
expect_no_diff() {
  local _generated="$1" _expected="$2"

  if [[ "${INIT:-false}" == "true" ]]; then
    mkdir -p "$(dirname "$_expected")"
    cp "$_generated" "$_expected"
    echo "      (init) wrote $_expected"
    _pass_=true
    _actual_="wrote $_expected"
    _expected_="no diff (init mode)"
    _negation_check_
    return
  fi

  if [[ ! -f "$_expected" ]]; then
    _pass_=false
    _actual_="MISSING expected file: $_expected (run with INIT=true to create)"
    _expected_="no diff vs $_expected"
    _negation_check_
    return
  fi

  if diff -q "$_generated" "$_expected" >/dev/null 2>&1; then
    _pass_=true
    _actual_="files match"
    _expected_="no diff between $_generated and $_expected"
  else
    _pass_=false
    _actual_="files differ (see diff below)"
    _expected_="no diff between $_generated and $_expected"
    diff "$_generated" "$_expected" | head -20 >&2
  fi
  _negation_check_
}

# expect_jq mirrors expect: it accumulates <file> and <expr> into
# _actual_, then dispatches to the trailing matcher (to_be, to_match).
# Mirrors the shape `expect <file> to_exist` from bash-spec.sh.
#
#   expect_jq "$PATH/file.json" ".services.web.image" to_be "nginx:1.27"
#   expect_jq "$PATH/file.json" ".services.web.image" to_match "nginx"
function expect_jq {
  _expected_=
  _negation_=false
  _pass_=false
  declare -a _actual_
  until [[ "${1:0:3}" == to_ || "$1" == not || -z ${1+x} ]]; do
    _actual_+=("$1")
    shift
  done
  # Resolve the jq value now and overwrite _actual_ with a single-element
  # array so downstream matchers (to_be, to_match) see a scalar — same
  # shape they get from plain `expect <value> ...`.
  local _file="${_actual_[0]}" _expr="${_actual_[1]}"
  if [[ -z "$_file" || -z "$_expr" ]]; then
    echo "**** FAIL - expect_jq: usage: expect_jq <file> <expr> to_be <value>" >&2
    (( _failed_+=1 ))
    return 1
  fi
  local _val
  _val=$(jq -r "$_expr" "$_file") || {
    echo "**** FAIL - expect_jq: jq error on '$_expr' '$_file'" >&2
    (( _failed_+=1 ))
    return 1
  }
  _actual_=("$_val")
  "$@"
}

# expect_no_diff_no_xsource: like expect_no_diff, but strips the
# `x-source:` line from both files before comparing. The x-source
# field on the merged record is provenance metadata (the literal
# path the user passed to `use`) and varies per call site, so
# golden comparisons must ignore it.
#
# Implementation: write stripped copies to a side-by-side temp
# location, then delegate to expect_no_diff. INIT mode copies
# the stripped file to the expected path — useful for the case
# where the golden has an old x-source: line and you want to
# update it.
expect_no_diff_no_xsource() {
  local _generated="$1" _expected="$2"
  local _gen_strip="${_generated}.no-xsource"
  local _exp_strip="${_expected}.no-xsource"
  grep -v '^x-source:' "$_generated" > "$_gen_strip"
  if [[ -f "$_expected" ]]; then
    grep -v '^x-source:' "$_expected" > "$_exp_strip"
  else
    # expect_no_diff will report the missing file clearly.
    : > "$_exp_strip"
  fi
  expect_no_diff "$_gen_strip" "$_exp_strip"
  rm -f "$_gen_strip" "$_exp_strip"
}

# expect_podman_compose: run `podman-compose -f <yaml> config`
# and assert success. Skips silently (with a "(skipped)" note
# on stdout) if podman-compose isn't on PATH, so the test still
# passes in environments without podman.
#
# Usage:
#   expect_podman_compose "out/dummy/compose.yaml"
#   expect_podman_compose            # default: out/dummy/compose.yaml
expect_podman_compose() {
  local _yaml="${1:-out/dummy/compose.yaml}"
  if command -v podman-compose >/dev/null 2>&1; then
    podman-compose -f "$_yaml" config >/dev/null
    should_succeed
  else
    echo "(skipped — podman-compose not installed)"
    true
  fi
}