#!/usr/bin/env bash
# bin/nickel-run.sh — generic nickel invocation wrapper.
#
# NOTE: this script is a candidate to extract from nickel-compose into
# its own repo (e.g. `nickel-run`). It has no nickel-compose-specific
# logic — it doesn't set NICKEL_IMPORT_PATH, doesn't import the merge
# engine, and doesn't touch compose semantics. Anything in this repo
# that wants to call it would resolve it as a sibling repo on PATH.
# A Rust rewrite is also worth considering: almost all of this script
# is string-templating (build the wrapper file) plus a `nickel eval`
# subprocess call, both of which are more pleasant as a small Rust
# binary that takes the same CLI shape.
#
# A pure tool. Takes one or more named input files, builds a temp
# wrapper that imports each as a Nickel value, evaluates a user-
# supplied expression against them, and prints the result.
#
# Usage:
#   nickel-run [--keep] [--format FMT] [--raw] [--out FILE] \
#              NAME=PATH [NAME=PATH...] -- EXPRESSION
#
# Arguments:
#   --keep          Leave the temp wrapper on disk for debugging
#                   (printed to stderr).
#   --format FMT    Output format: ncl (default), json, yaml, yml,
#                   toml, env, bash. Non-ncl formats pipe through
#                   `nickel export --format FMT` (except env and
#                   bash, which use `--format json` internally then
#                   jq-translate). env emits dotenv-style KEY=VALUE
#                   per line; bash emits sourceable bash syntax
#                   with arrays as KEY=(...).
#   --raw           Strip enclosing quotes from the result. Only
#                   meaningful with --format json (the format the
#                   shell sees first); pipes through `jq -r` after
#                   export. Behavior depends on the result type:
#                     - scalar: prints the value unquoted
#                       (e.g. nginx:1.27, not "nginx:1.27")
#                     - array of scalars: prints one element per line
#                     - record / object: prints unchanged
#                       (quotes around keys are required JSON)
#                   Use for piping into shell scripts that want one
#                   value or one-per-line. For structured output
#                   you intend to query, omit --raw and pipe
#                   through jq with your own filter. Errors if
#                   combined with --format ncl/yaml/yml/toml,
#                   because `jq -r` only understands JSON.
#   --out FILE      Write output to FILE instead of stdout. If FILE
#                   resolves to one of the inputs, error out
#                   instead of clobbering.
#   NAME=PATH       One or more named inputs. PATH is the file to
#                   import; extension is irrelevant (nickel handles
#                   .ncl/.json/.yml/.yaml natively via `import`).
#                   NAME must be a valid Nickel identifier
#                   ([A-Za-z_][A-Za-z0-9_]*). ~ in PATH is
#                   expanded to $HOME.
#   --              Separator. Everything after is the Nickel
#                   expression to evaluate, collected as a single
#                   string.
#
# Scope inside the expression:
#   NAME            The imported value of each input (free
#                   identifier, one per NAME=PATH).
#   _paths = { NAME = "ABS_PATH", ... }
#                   A record mapping each name to its absolute
#                   path. The leading underscore marks this as
#                   a tool-injected name; it lets you bind a
#                   user input called "paths" without collision.
#                   Use _paths.NAME to get the source path
#                   string (e.g. for x-source provenance).
#
# The expression is one Nickel expression. Each NAME from a
# NAME=PATH pair is bound as a free identifier — write
# `cfg.services` not `run.cfg.services`. Common usage:
#   nickel-run cfg=config.ncl -- 'cfg.services'
#   nickel-run cfg=config.ncl -- 'compose.merge_with_source cfg _paths.cfg'
#
# This tool does NOT set NICKEL_IMPORT_PATH. The user controls that.
# Layered tools (nickel-compose-run) carry domain-specific import
# paths.
#
# Examples:
#   nickel-run f=foo.ncl -- 'f'
#   nickel-run f=foo.yml -- 'std.record.fields f'
#   nickel-run cfg=config.ncl lib=lib.ncl -- \
#     'lib.process cfg _paths.cfg'

set -euo pipefail

KEEP=0
FORMAT="ncl"
RAW=0
OUT=""
NAMES=()
PATHS=()
WRAPPER=""

# --- arg parsing ---

usage() {
  local rc="${1:-0}"
  sed -n '2,/^$/p' "$0" | sed 's/^# \?//' >&2
  exit "$rc"
}

# Validate that a name is a usable Nickel identifier for a let
# binding. Nickel accepts unquoted identifiers matching this
# pattern; anything else (spaces, hyphens, dots) would need
# quoting. We reject and ask the user to pick a different name.
valid_name() {
  local n="$1"
  [[ "$n" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

cleanup() {
  # Run on EXIT. Removes the wrapper file if --keep wasn't set.
  # Always safe to call; uses rm -f.
  if [[ -n "$WRAPPER" && $KEEP -eq 0 ]]; then
    rm -f "$WRAPPER" "$WRAPPER.paths"
  fi
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep)
      KEEP=1
      shift
      ;;
    --raw)
      RAW=1
      shift
      ;;
    --format)
      FORMAT="$2"
      shift 2
      ;;
    --out)
      OUT="$2"
      shift 2
      ;;
    -h|--help)
      usage 0
      ;;
    --)
      shift
      break
      ;;
    --*)
      echo "unknown flag: $1" >&2
      usage 1
      ;;
    *=*)
      name="${1%%=*}"
      path="${1#*=}"
      if [[ -z "$name" || -z "$path" ]]; then
        echo "malformed NAME=PATH: '$1'" >&2
        usage 1
      fi
      if ! valid_name "$name"; then
        echo "invalid name '$name' (must match [A-Za-z_][A-Za-z0-9_]*)" >&2
        usage 1
      fi
      NAMES+=("$name")
      PATHS+=("$path")
      shift
      ;;
    *)
      echo "unexpected positional: '$1' (use -- before the expression)" >&2
      usage 1
      ;;
  esac
done

EXPR="$*"
if [[ -z "$EXPR" ]]; then
  echo "no expression given (use -- EXPR)" >&2
  usage 1
fi
if [[ ${#NAMES[@]} -eq 0 ]]; then
  echo "no NAME=PATH inputs given" >&2
  usage 1
fi

# --- validate inputs ---

# Reject duplicate names — would clash in record literal and
# produce ambiguous bindings in the expression.
for i in "${!NAMES[@]}"; do
  for j in "${!NAMES[@]}"; do
    if [[ "$i" -ne "$j" && "${NAMES[$i]}" == "${NAMES[$j]}" ]]; then
      echo "duplicate name: '${NAMES[$i]}'" >&2
      exit 1
    fi
  done
done

# Resolve each path to absolute, verify it exists. Also
# expand a leading ~ to $HOME (no-op for paths that don't
# start with ~).
ABS_PATHS=()
for path in "${PATHS[@]}"; do
  # Tilde expansion. Only the leading ~ is special; ~/foo or
  # ~user/foo. Other forms (~ inside the path) are left alone.
  case "$path" in
    "~"|"~/"*)  path="$HOME${path#\~}" ;;
    "~"*)       ;;  # ~user — could expand via getent, but skip
                  # for now: not a documented feature.
  esac
  # Reject paths containing characters that would break the
  # generated Nickel wrapper. We embed each path in a
  # double-quoted Nickel string literal; backslash and
  # double-quote are the only characters that need escaping
  # there. We don't bother escaping — just reject, since
  # such paths are vanishingly rare in practice. Check
  # this BEFORE stat-ing so the error is clear even if the
  # bad path doesn't exist.
  if [[ "$path" == *'"'* ]]; then
    echo "path contains a double-quote: $path" >&2
    echo "nickel-run cannot embed such paths in its wrapper" >&2
    exit 1
  fi
  if [[ "$path" == *'\'* ]]; then
    echo "path contains a backslash: $path" >&2
    echo "nickel-run cannot embed such paths in its wrapper" >&2
    exit 1
  fi
  if [[ ! -e "$path" ]]; then
    echo "input not found: $path" >&2
    exit 1
  fi
  if [[ ! -f "$path" ]]; then
    echo "not a regular file: $path" >&2
    exit 1
  fi
  abs="$path"
  if [[ "$abs" != /* ]]; then
    abs="$(cd "$(dirname "$abs")" && pwd)/$(basename "$abs")"
  fi
  ABS_PATHS+=("$abs")
done

# If --out was given, refuse to clobber an input. We compare
# the resolved --out path against each resolved input.
if [[ -n "$OUT" ]]; then
  out_abs="$OUT"
  if [[ "$out_abs" != /* ]]; then
    out_abs="$(cd "$(dirname "$out_abs")" 2>/dev/null && pwd)/$(basename "$out_abs")" || out_abs="$OUT"
  fi
  for abs in "${ABS_PATHS[@]}"; do
    if [[ "$abs" == "$out_abs" ]]; then
      echo "--out would clobber input '$abs'" >&2
      echo "use a different output path" >&2
      exit 1
    fi
  done
fi

# --- build the wrapper ---

# Single temp file with:
#   - one `let NAME = (import "PATH")` per NAME=PATH (the
#     imported value bound as a free identifier)
#   - one `_paths` record mapping NAME → "ABS_PATH"
#   - the user's expression
# Errors from nickel point at this file; --keep leaves it for
# inspection.
WRAPPER="$(mktemp /tmp/nickel-run-XXXXXX.ncl)"

# Generate the paths record in a separate file so the user's
# expression can still reference _paths.NAME. The underscore
# prefix is a tool-injected convention; see the file header
# for the rationale.
{
  echo "{"
  for i in "${!NAMES[@]}"; do
    sep=","
    [[ "$i" -eq $((${#NAMES[@]} - 1)) ]] && sep=""
    printf '  %s = "%s"%s\n' "${NAMES[$i]}" "${ABS_PATHS[$i]}" "$sep"
  done
  echo "}"
} > "$WRAPPER.paths"

# The eval target. One let per input, then `let _paths = ...`,
# then the expression. The expression is line 2 + NAMES, so
# most user errors point at the right place.
{
  for i in "${!NAMES[@]}"; do
    printf 'let %s = (import "%s") in\n' "${NAMES[$i]}" "${ABS_PATHS[$i]}"
  done
  printf 'let _paths = import "%s" in\n' "$WRAPPER.paths"
  echo "$EXPR"
} > "$WRAPPER"

# --- run ---

# Map format aliases. yml → yaml; ncl → raw eval (no export).
# env and bash are jq-based sinks (not nickel export formats) —
# we still run `nickel export --format json` and pipe through jq.
case "$FORMAT" in
  ncl)  EXPORT_FMT="" ;;
  yml)  EXPORT_FMT="yaml" ;;
  yaml|json|toml) EXPORT_FMT="$FORMAT" ;;
  env|bash)  EXPORT_FMT="json" ;;  # format used internally; env/bash post-processed
  *)
    echo "unknown format: $FORMAT (use ncl, json, yaml, yml, toml, env, bash)" >&2
    exit 1
    ;;
esac

# --raw only makes sense over JSON (the format the shell sees after
# the export). For ncl/yaml/yml/toml we'd need a format-specific
# unquoter; the only case users actually hit is JSON scalars, so
# we restrict to that.
if [[ $RAW -eq 1 && "$EXPORT_FMT" != "json" ]]; then
  echo "--raw requires --format json (got: $FORMAT)" >&2
  echo "  --raw pipes through 'jq -r', which only understands JSON." >&2
  exit 1
fi
if [[ $RAW -eq 1 ]] && ! command -v jq >/dev/null 2>&1; then
  echo "--raw requires 'jq' on PATH" >&2
  exit 1
fi

if command -v mise >/dev/null 2>&1; then
  NICKEL="mise exec -- nickel"
else
  NICKEL="nickel"
fi

# Format-specific post-processor applied AFTER nickel export and
# AFTER --raw. Most formats are pass-through. env emits dotenv
# format (KEY=VALUE per line, JSON-encoded values). Using --raw
# with env is an error because the two are alternatives, not
# composable: --raw flattens arrays to one-per-line, env keeps
# the structure as quoted KEY=VALUE pairs.
case "$FORMAT" in
  env)
    if [[ $RAW -eq 1 ]]; then
      echo "--raw cannot be combined with --format env" >&2
      echo "  env is already a flattened KEY=VALUE format." >&2
      exit 1
    fi
    # Flatten any JSON value to KEY=VALUE per line, parseable by
    # dotenv consumers (direnv, docker --env-file, etc.). Objects:
    # KEY=VALUE per field. Arrays: INDEX=VALUE per element
    # (0-indexed). Scalars: just the value on its own line. Nested
    # values are JSON-encoded on the right-hand side so special
    # characters don't break parsing. Not directly bash-sourceable
    # for arrays — use --format bash for that.
    POST='jq -r "if type == \"object\" then to_entries[] | \"\(.key)=\(.value | tojson)\" elif type == \"array\" then to_entries[] | \"\(.key)=\(.value | tojson)\" else . end"'
    ;;
  bash)
    if [[ $RAW -eq 1 ]]; then
      echo "--raw cannot be combined with --format bash" >&2
      echo "  bash is already an unquoted, sourceable format." >&2
      exit 1
    fi
    # Emit bash-sourceable output: KEY=VAL for scalars (unquoted
    # when safe, single-quoted otherwise), KEY=(...) for arrays,
    # and KEY=(["k"]="v" ...) for nested objects (declare -A is
    # not assumed; bash 4+ associative arrays). Top-level scalars
    # print on their own line. Indented with tabs for readability.
    POST='jq -r "
      def bashq: if type == \"string\" then
        if test(\"^[A-Za-z0-9_./:,-]+$\") then . else \"\\\"\" + . + \"\\\"\" end
      elif type == \"number\" or type == \"boolean\" then tostring
      else tojson end;
      def emit:
        if type == \"object\" then
          to_entries[] | \"\(.key)=\(if .value | type == \"array\" then \"(\" + ([.value[] | bashq] | join(\" \")) + \")\" elif .value | type == \"object\" then \"(\" + ([.value | to_entries[] | \"[\" + (.key | bashq) + \"]=\" + (.value | bashq)] | join(\" \")) + \")\" else .value | bashq end)\"
        elif type == \"array\" then
          to_entries[] | \"\(.key)=\(.value | bashq)\"
        else .
        end;
      emit
    "'
    ;;
  *)
    POST=""
    ;;
esac

RC=0
if [[ -n "$OUT" ]]; then
  # Re-run to capture into the file. The pipe is small enough
  # that a second eval is simpler and avoids buffering edge
  # cases. When --out is given, suppress stdout.
  if [[ -n "$EXPORT_FMT" ]]; then
    if [[ -n "$POST" ]]; then
      eval "$NICKEL eval \"$WRAPPER\" | $NICKEL export --format \"$EXPORT_FMT\" | $POST" "> \"$OUT\"" '|| RC=$?'
    elif [[ $RAW -eq 1 ]]; then
      $NICKEL eval "$WRAPPER" | $NICKEL export --format "$EXPORT_FMT" | jq -r 'if type == "array" then .[] else . end' > "$OUT" || RC=$?
    else
      $NICKEL eval "$WRAPPER" | $NICKEL export --format "$EXPORT_FMT" > "$OUT" || RC=$?
    fi
  else
    $NICKEL eval "$WRAPPER" > "$OUT" || RC=$?
  fi
else
  if [[ -n "$EXPORT_FMT" ]]; then
    if [[ -n "$POST" ]]; then
      eval "$NICKEL eval \"$WRAPPER\" | $NICKEL export --format \"$EXPORT_FMT\" | $POST" '|| RC=$?'
    elif [[ $RAW -eq 1 ]]; then
      $NICKEL eval "$WRAPPER" | $NICKEL export --format "$EXPORT_FMT" | jq -r 'if type == "array" then .[] else . end' || RC=$?
    else
      $NICKEL eval "$WRAPPER" | $NICKEL export --format "$EXPORT_FMT" || RC=$?
    fi
  else
    $NICKEL eval "$WRAPPER" || RC=$?
  fi
fi

if [[ $RC -ne 0 && $KEEP -eq 0 ]]; then
  # On failure, keep the wrapper so the user can inspect the
  # error. Print the path so they know where it is.
  echo "wrapper kept for debugging: $WRAPPER" >&2
  KEEP=1
fi

if [[ $KEEP -eq 1 ]]; then
  echo "wrapper kept: $WRAPPER" >&2
  echo "  paths record: $WRAPPER.paths" >&2
fi

exit $RC
