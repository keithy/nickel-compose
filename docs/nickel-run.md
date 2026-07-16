# nickel-run — a wrapper spec

This document specifies `bin/nickel-run.sh`, a generic Nickel
invocation wrapper. It exists because the upstream `nickel` CLI
lacks a native equivalent, and `nickel-compose` needs the
functionality to query, transform, and re-emit Nickel/JSON/YAML
documents without the user writing boilerplate every time.

The proposal here is also the shape of a native `nickel run`
subcommand we want to see in Nickel itself.

## Why this exists

Nickel already has:

- `nickel eval FILE` — evaluate and pretty-print
- `nickel export --format FMT FILE` — serialize to JSON/YAML/TOML
- `nickel typecheck FILE` — typecheck
- `nickel query --field PATH FILE` — read metadata

What's missing is a way to **bind N inputs to names, evaluate an
expression against them, and serialize the result**. Every
non-trivial CLI tool that wants to "do something with a Nickel
file" ends up:

1. Writing a temp wrapper file with `let NAME = import "PATH" in EXPR`
2. Running `nickel eval wrapper.ncl`
3. Piping through `nickel export --format FMT` if a non-ncl format is wanted
4. Cleaning up

This is `bin/nickel-run.sh`. It's ~250 lines of bash for what is
fundamentally "load N files, evaluate an expression, serialize."

## CLI

```
nickel-run [--keep] [--format FMT | --raw] [--out FILE]
           NAME=PATH [NAME=PATH...] -- EXPRESSION
```

### Arguments

- `--keep` — leave the temp wrapper on disk for debugging.
  The path is printed to stderr.
- `--format FMT` — output format: `ncl` (default), `json`,
  `yaml`, `yml`, `toml`, `raw`, `env`, `bash`. Most formats pipe
  through `nickel export --format FMT`. `raw`, `env`, and `bash`
  use `json` internally then `jq`-translate.
- `--raw` — alias for `--format raw`. Flattens the result for
  shell consumption:
  - **scalar**: prints the value unquoted (`nginx:1.27`)
  - **array of scalars**: one element per line
  - **record/object**: passes through unchanged

  If both `--format FMT` and `--raw` are passed, the last one
  wins (no error). Use the explicit form only when you want a
  specific format flag for clarity.
- `--out FILE` — write to FILE instead of stdout. Refuses to
  clobber an input.
- `NAME=PATH` — one or more named inputs. `NAME` must be a valid
  Nickel identifier (`[A-Za-z_][A-Za-z0-9_]*`). `~` in PATH
  expands to `$HOME`. Rejects paths with `"` or `\` (would break
  the generated wrapper).
- `--` — separator. Everything after is the Nickel expression.

### Scope inside the expression

- `NAME` — the imported value of each input (free identifier).
- `_paths = { NAME = "ABS_PATH", ... }` — record mapping each
  name to its absolute path. Underscore prefix marks it as
  tool-injected; lets the user bind a name called `paths` without
  collision.

The expression is one Nickel expression. Single result, no
multi-statement scripts.

### Format details

| Format | Internal pipeline             | Notes                                   |
|--------|-------------------------------|-----------------------------------------|
| `ncl`  | `nickel eval`                 | default                                 |
| `json` | `eval \| export --format json`| most interoperable                      |
| `yaml` | `eval \| export --format yaml`|                                         |
| `yml`  | `eval \| export --format yaml`| alias                                   |
| `toml` | `eval \| export --format toml`|                                         |
| `raw`  | `eval \| export \| jq flatten`| scalars unquoted, arrays one per line   |
| `env`  | `eval \| export \| jq dotenv` | `KEY=VALUE` per line, JSON-encoded vals |
| `bash` | `eval \| export \| jq bash`   | sourceable; arrays as `KEY=(a b c)`     |

`raw`, `env`, and `bash` are jq translations of the JSON
export; they share the `--format json` pipeline and add a final
`jq -r` step. The user-supplied jq filter is what differentiates
them.

## Output examples

```bash
# 1. Load a file, print it
$ nickel-run cfg=my-config.ncl -- 'cfg'
{ services = { web = { image = "nginx:1.27" } } }

# 2. Apply a stdlib function
$ nickel-run cfg=my-config.ncl -- 'std.record.fields cfg.services'
[ "web" ]

# 3. Format as YAML
$ nickel-run --format yaml cfg=my-config.ncl -- 'cfg'
services:
  web:
    image: nginx:1.27

# 4. Format as JSON
$ nickel-run --format json cfg=my-config.ncl -- 'cfg'
{
  "services": {
    "web": {
      "image": "nginx:1.27"
    }
  }
}

# 5. Raw scalar (unquoted)
$ nickel-run --raw cfg=my-config.ncl -- 'cfg.services.web.image'
nginx:1.27

# 6. Raw array (one per line)
$ nickel-run --raw cfg=my-config.ncl -- 'std.record.fields cfg.services'
web
db
redis

# 7. Dotenv format
$ nickel-run --format env cfg=my-config.ncl -- 'cfg'
services={"web":{"image":"nginx:1.27"}}

# 8. Bash-sourceable (arrays round-trip)
$ nickel-run --format bash cfg=my-config.ncl -- 'cfg'
services=(["web"]=image="nginx:1.27")

# 9. Attach provenance via _paths
$ nickel-run cfg=my-config.ncl -- 'cfg & { x-source = _paths.cfg }'
{ services = { ... }, x-source = "/abs/path/to/my-config.ncl" }
```

## The wrapper file

The tool generates a temp file with this shape:

```nickel
let NAME1 = import "/abs/path/to/input1" in
let NAME2 = import "/abs/path/to/input2" in
let _paths = import "/abs/path/to/wrapper.paths" in
EXPR
```

Where `wrapper.paths` contains:

```nickel
{ NAME1 = "/abs/path/to/input1", NAME2 = "/abs/path/to/input2" }
```

Both files are deleted on EXIT unless `--keep` is set.

## Conformance suite

The wrapper has a bash-spec test suite at
`tests/nickel_run_spec.sh` (72 assertions, one `describe` block).
This is the contract a native implementation must satisfy. The
suite is grouped by topic:

- **Loading inputs** — single file, multi-file, json/yml/ncl
  inputs accepted by extension, `_paths` injection.
- **Path handling** — tilde expansion, double-quote and backslash
  rejection, missing-file errors, clobber protection.
- **Identifier validation** — spaces, hyphens, leading digits,
  underscores and digits allowed.
- **Name conflicts** — duplicate names rejected.
- **Expression parsing** — bare positional without `--` rejected,
  missing expression rejected.
- **Format dispatch** — `ncl` default, `json`/`yaml`/`yml`/`toml`
  pass through `nickel export --format FMT`, `env`/`bash` are
  jq-translated.
- **`--raw` / `--format raw` behavior** — scalar → unquoted,
  array of scalars → one per line, record → unchanged; alias
  for `--format raw`; last `--format`/`--raw` wins if both given.
- **`--out FILE`** — writes to file, refuses to clobber inputs.
- **`--keep`** — leaves wrapper on disk on failure.
- **Error handling** — eval failure keeps wrapper for inspection;
  unknown flags rejected.

The conformance suite is the authoritative spec. The prose above
is rationale and examples; the bash assertions are the contract.
A native Rust implementation that passes all 72 assertions with
identical stdout/stderr/exit-code behavior is a drop-in
replacement.

## What a native `nickel run` should look like

The wrapper exists because the upstream CLI doesn't have this
subcommand. The proposed native equivalent:

```
nickel run [--format FMT | --raw] [--out FILE]
           NAME=PATH [NAME=PATH...] -- EXPRESSION
```

Same CLI shape, no temp file. The bindings land in the evaluator's
environment directly. `_paths` is a builtin module available to
the expression.

A native implementation would replace ~250 lines of bash with a
`clap` derive struct and the existing `nickel eval` infrastructure
plus an in-process JSON serializer (or a `to_json` method on
`Term`). No subprocess for the eval step. No `jq` invocation.
No temp file cleanup.

The format dispatch would live in the same place as `nickel
export`'s format dispatch — same code path, just routed through
the bindings from `nickel run`'s argv.

### Estimated win

Per invocation, the wrapper:

- Forks 1-3 subprocesses (`nickel eval`, `nickel export`, `jq`)
- Writes 1-2 temp files
- Reads each input twice (once for the wrapper's import, once
  again when nickel actually loads it)

A native impl: one process, no temp files, one read per input.

For the workload `nickel-compose use` does (one call per
`compose.ncl` render), the wrapper is fast enough that the
overhead is invisible. For tooling that calls `nickel-run` in a
loop (linters, formatters, IDE queries), the subprocess overhead
starts to matter.

## Status

- Wrapper: shipped in `bin/nickel-run.sh`.
- `--format env` and `--format bash` are jq-based and not
  available in `nickel export` upstream.
- `--raw` is jq-based; a native impl could read the `Term`'s type
  and decide on serialization directly.
- Conformance suite: `tests/nickel_run_spec.sh` (72 assertions).
  A native Rust implementation must pass this spec verbatim to
  count as a drop-in replacement.
- Issue tracker: [nickel-lang/nickel#2636](https://github.com/nickel-lang/nickel/issues/2636)