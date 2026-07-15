# SCHEMA — Contracts and Validation

Schema validation is the main reason to use nickel-compose over
plain Compose YAML. With it, you find typos in service names,
missing `image` fields, and wrong port shapes at typecheck time
— before any container starts.

## What you get

`nickel-compose.ncl` exports five contracts and one validator:

| Name | Shape | What it constrains |
|---|---|---|
| `composer.Service` | record | one service: image, build, command, env, volumes, ports, depends_on, networks, restart, init |
| `composer.Port` | record | one long-form port entry: target, published, protocol, host_ip |
| `composer.Volume` | record | one top-level volume: driver, driver_opts, external, name |
| `composer.Network` | record | one top-level network: driver, external, name |
| `composer.Fragment` | record | one entry in the fragments list: services, volumes, networks, if_present, if_absent |
| `composer.check` | function | runs schema checks on a merged record, returns `{ ok, errors }` |
| `composer.merge_with_check` | function | like `merge` but attaches the check result as a `_check` field |

Contracts are records with field-level `| doc "..."` annotations.
The LSP reads them for hover docs and field-name autocompletion.
`composer.check` enforces the rules that catch the bugs that hurt
(missing `image`/`build`).

## How the engine checks a config

`composer.check` walks the merged record (after merge and
conditionals resolved) and returns a structured report:

```nickel
let composer = import "nickel-compose.ncl" in
let merged = composer.merge [...] in
composer.check merged
# -> { ok = true, errors = [] }
# or
# -> {
#      ok = false,
#      errors = [
#        {
#          service = "web",
#          field = "image",
#          message = "service must declare `image` or `build`",
#        }
#      ],
#    }
```

For v0.2.0, the only enforced rule is **every service must have
`image` or `build`**. Port validation, depends_on reference
checking, and other rules are queued for later rounds — see
[the roadmap](#roadmap) below.

## Two ways to wire the check into your config

### Option A: `merge_with_check` (recommended)

Use `composer.merge_with_check` instead of `composer.merge` at the
end of your `config.ncl`:

```nickel
let composer = import "nickel-compose.ncl" in

let fragments = [
  import "./base.ncl",
  import "./services/web.ncl",
  # ...
] in

composer.merge_with_check fragments
```

The result is a record that includes a `_check` field with the
schema report. The `_check` field is annotated `not_exported`, so
`nickel export` strips it from `compose.yaml`. `nickel eval`
keeps it (so tooling can read it).

### Option B: explicit `check` call

If you want to do something with the merged record between merge
and check — log a summary, transform it, fail-fast on a specific
condition — use plain `merge` and call `check` explicitly:

```nickel
let composer = import "nickel-compose.ncl" in

let fragments = [ /* ... */ ] in
let merged = composer.merge fragments in
let report = composer.check merged in

{
  merged = merged,
  report = report,
}
```

This pattern is shown in `examples/dummy-project/config_with_check.ncl`.
Use it when you need the merged record in two places, or when you
want to add your own custom checks on top of the engine's.

## How the wrapper uses `_check`

`scripts/to-compose.sh` always:

1. Writes `compose.ncl` (canonical — with `_check` attached)
2. Writes `compose.yaml` (derived — `_check` stripped via a small
   helper that destructures the merged record)
3. Reads `_check.ok` back from `compose.ncl` via a one-line
   `nickel eval` query
4. Exits 0 if `_check.ok == true`, 1 otherwise
5. Always produces both artifacts (so `podman compose config`
   can debug a broken state — the bug is visible, not hidden)

The exit code is non-zero on schema failure **even though the
artifacts are written**. CI catches it; humans iterating see
the broken `compose.yaml` and can poke at it with
`podman compose config` to understand what went wrong.

For configs that use plain `merge` (not `merge_with_check`),
the wrapper prints `schema: not checked` and exits 0. This
preserves backward compatibility for existing configs.

## Strict typecheck: `mise run check`

`mise run check` (or `./scripts/check.sh`) runs
`nickel typecheck` on the engine and (optionally) a user
`config.ncl`. The user-config argument is passed through:

```bash
mise run check                       # engine only
mise run check -- examples/proj/config.ncl  # engine + user config
```

`nickel typecheck` enforces the contract records at use sites.
If a service is missing `image` or has the wrong port shape, the
typecheck fails with a file:line error.

## Why contracts aren't on `composer.merge` itself

In nickel 1.17, value annotations (`: Service = ...`) are treated
as static types. They reject record literals that don't exactly
match, which breaks `nickel export` for any config that constructs
records dynamically (e.g. from imported YAML). So:

- Contracts are exposed as **values** (records with field-level
  doc/default). The LSP reads them for hover and autocompletion.
- Validation runs through **`composer.check`**, which is plain
  record matching and works in both `eval` and `export`.

This is a nickel 1.17 limitation. A future nickel release may
support contract annotations that don't break export, in which
case the contracts can be enforced at the use site directly.

## Scope: minimal by design

`composer.Service` contracts only the fields the engine consumes
or that catch the most common Compose bugs:

- `image` and `build` (the required-or-build rule)
- `command`, `environment`, `volumes`, `ports`, `depends_on`,
  `networks` (the typed payload)
- `restart`, `init` (defaults the engine fills in)

Everything else — `healthcheck`, `secrets`, `deploy`,
`logging`, `cap_add`, `extra_hosts`, etc. — passes through as
untyped data. The door stays open for a more comprehensive
`ServiceComprehensiveSchema` later.

## Roadmap

Queued for later rounds:

- **Port validation** — `composer.validation.ports` flags
  malformed port strings, bind-address forms, conflicting
  host port bindings across services.
- **Depends_on resolution** — `composer.validation.dependencies`
  walks `depends_on` and reports dangling references. A
  `service.redis.yml` that references `redis` but isn't matched
  by any other fragment would surface as an error.
- **Top-level volume/network consistency** — synthesize already
  fills in missing top-level declarations, but doesn't flag
  inconsistent declarations (a `volumes:` entry declared with
  `driver: local` in one fragment and `driver: nfs` in another).
- **Image format** — optional `nickel-compose-validation-rules`
  package for things like "no `:latest` tags" or "all images
  must pin a major version."

None of these are blocking; the v0.2.0 milestone is about the
plumbing (contracts, check, merge_with_check, _check annotation,
wrapper integration). The actual rules can land incrementally
without further engine changes.

## Worked example: catching a typo

Without schema check, a typo in a service name silently
produces a broken `compose.yaml` that fails at `podman compose up`
with an unhelpful error:

```nickel
# config.ncl with a typo
let composer = import "nickel-compose.ncl" in
let fragments = [
  { services = { webb = { image = "nginx:1.27" } } },  # typo: 'webb' not 'web'
] in
composer.merge_with_check fragments
# => { ..., _check = { ok = false, errors = [
#      { service = "webb", field = "image", message = "..." }
#    ]}}
```

`scripts/to-compose.sh` exits 1 with `schema: errors found`.
`podman compose config` (against the written `compose.yaml`)
shows what would have happened at `up` time.

## File-by-file

| File | What changed in v0.2.0 |
|---|---|
| `nickel-compose.ncl` | Added `Service`/`Port`/`Volume`/`Network`/`Fragment` contracts, `check` function, `merge_with_check` function. Bumped version to 0.2.0. |
| `scripts/check.sh` | New. Strict typecheck of engine and optional user config. |
| `scripts/to-compose.sh` | Uses `merge_with_check` (via the wrapper-generated config.ncl), reads `_check.ok` to set exit code, always produces artifacts, summary to stderr. |
| `scripts/from-nickel-compose.sh` | Generates `config.ncl` ending in `composer.merge_with_check fragments`. |
| `mise/tasks/check` | Now wraps `scripts/check.sh`. |
| `tests/schema_spec.sh` | New. 44 tests for contracts, check, merge_with_check, wrapper integration. |
| `examples/dummy-project/config_ncl.ncl` | Uses `merge_with_check` for schema validation. |
| `examples/dummy-project/config_with_check.ncl` | New. Shows explicit `check` call pattern. |
