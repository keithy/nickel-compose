# Agent Instructions for nickel-compose

Generic agent rules are in the parent-level `../AGENTS.md`

## Testing 

- Tests are bash scripts in `tests/*_spec.sh` using the
  vendored `tests/lib/bash-spec.sh` (bash-spec 2.1).
- `tests/_run.sh` runs them all in order.
- Each spec runs in its directory — paths in the
  test body are relative to the spec file, not the project.
- NICKEL_IMPORT_PATH is set per-spec to the project root
  so fixtures can use `import "nickel-compose.ncl"` without
  a path prefix.
- Golden files in `tests/expected/` are byte-equality
  targets. Set `INIT=true bash tests/_run.sh` to regenerate.
- `tests/out/` is gitignored. Tests clean it at start.
- All tests should pass

Common assertion patterns:
- `nickel export --format json <file> > <out>` then
  `expect_jq <out> '.foo.bar' to_be "expected"`
- `bash scripts/something.sh` then `should_succeed` / `should_fail`
- `expect <file> to_exist` for file existence
- `expect_no_diff <gen> <expected>` for golden-file equality

For new tests, follow the clean example pattern in:
- `tests/conditionals_spec.sh`
- `tests/schema_spec.sh`

## Engine structure (load this before editing the engine)

`nickel-compose.ncl` is a single file, ~660 lines. Top to
bottom:

1. `array_fields` — fields that concat on merge
2. `get_or` — field-access with default
3. `merge_records` — recursive record merge
4. `with_defaults` / `with_defaults_service` — fill in
   `networks: [default]`, `restart: unless-stopped`, `init: false`
5. `merge_compose` — top-level merge
6. `merge_all` — fold over a list
7. `vol_name_from_ref` / `synthesize_*` — top-level
   volume/network synthesis
8. `parse_gate_key` / `resolve_gates` / `resolve_conditionals`
   — `if_present` and `if_absent` logic
9. **Contracts** (v0.2.0): `service_schema`, `port_schema`,
   `volume_schema`, `network_schema`, `fragment_schema`
10. `check_service` / `run_check` — schema validator
11. `run_merge_with_check` — merge + attach `_check | not_exported`
12. The **public record** — what gets exported

## Gotchas (these have bitten me)

**Record field shadowing.** A let-binding with the same
name as a record field is shadowed by the field at evaluation
time. So `{ Service = Service }` recurses forever.

Workaround: name the let with a suffix and alias in the
record. Existing examples: `service_schema` (let) →
`Service = service_schema` (record), `run_check` →
`check = run_check`, `run_merge_with_check` →
`merge_with_check = run_merge_with_check`. **Don't rename
them back** — the field name is the public API, the let
name is implementation.

**Contract syntax order.** `| doc` must come before
`| default`. Other orderings parse fine but the engine
fails silently on field type.

**`| optional` strips the field entirely** from the
record's field list. `std.record.fields S` and
`std.record.has_field "x" S` both lie. Don't use it on
contracts the LSP should hover over.

**`_check | not_exported` annotation lifecycle.** The
annotation works in source code. `nickel export` honors it
and strips the field. But `nickel eval` serializes the
record as a literal that **drops** the annotation, so
subsequent `nickel export` on the eval output keeps the
field. The `to-compose.sh` wrapper works around this by
destructuring the record into a new literal. Don't try
to add the strip in the engine.

**Record merge `&` strips annotations.** `base & { hidden
| not_exported = "x" }` loses the `not_exported`. So
`synthesize` returns a record, and attaching `_check` via
`s & { _check | not_exported = run_check s }` doesn't work.
Workaround: destructure `s` and rebuild as a single literal
(see `run_merge_with_check`).

## `nickel query` (read metadata from source)

`nickel query <file> --field <path> [flag]` reads metadata
from a source file's AST. It works on **source files**, not
on `nickel eval` output (which is a literal that has dropped
all annotations).

Flags:
- `--doc` — print the `| doc "..."` annotation
- `--contract` — print the field's contract
- `--type` — print the field's type
- `--default` — print the `| default = ...` value
- `--value` — print the value
- `--format <json|yaml|...>` — output format (default markdown)
- `--field <dotted.path>` — query a specific field

The field path must point to a specific field, not a record
as a whole. `--field composer.Service` returns "no metadata"
because the record itself has no doc. `--field
composer.Service.image` returns "container image". To query
all fields of a contract, walk the field names from the
record's `record.fields` and call `nickel query` for each.

Use cases:
- **LSP-style hover**: `nickel query --field
  composer.Service.image --doc config.ncl` returns the doc
  comment. This is what tooling should use to surface
  contract docs to users.
- **Schema introspection**: `nickel query --field
  composer.Service --contract config.ncl` returns the full
  contract record. Useful for a `nickel-compose schema`
  command.
- **Default lookup**: `nickel query --field
  composer.Service.ports --default config.ncl` returns
  `[]`.

**What `nickel query` does NOT do:**
- Read `not_exported` annotations. There's no flag for it.
  `not_exported` is an export-time concern; the `nickel
  export` tool reads it directly when it serializes. Query
  tools don't see it.
- Operate on `nickel eval` output. Eval writes a record
  literal that has no annotations. Query on eval output
  returns "no metadata" for everything.
- Strip fields from output. That's `nickel export`'s job.
  `nickel query` reads; it doesn't transform.

For the LSP, `nickel query` is the right tool. For the
`_check` strip problem in the wrapper, it doesn't help.

## Compose `x-*` extension fields

The Compose spec reserves top-level fields with the `x-`
prefix as **extension fields**: silent to the runtime, free
to be used for custom metadata, tooling hints, or
experimental features. `podman compose config` and
`docker compose config` accept `x-*` without warning;
unknown fields without the `x-` prefix would be rejected.

This is useful for nickel-compose in two ways:

1. **Avoiding the `_check` strip problem.** If a field
   name starts with `x-`, no annotation is needed — the
   Compose runtime ignores it. The `x-` prefix is the
   convention. The current engine uses `_check` (with
   `| not_exported` and a wrapper-side strip); renaming
   to `x-check` would let the wrapper skip the strip
   entirely and the YAML would still be valid Compose.
2. **User-facing metadata.** Users can add their own
   `x-*` fields to fragments for any purpose: cost
   centers, owner teams, deploy notes. The engine
   preserves them through the merge (it's just a regular
   record field). They flow into the rendered YAML and
   are ignored by `podman compose`, but tooling can read
   them.

When designing a new metadata field, ask: does the
runtime need to ignore it? If yes, use `x-`. If it should
flow into the schema validation (e.g. it's a constraint
the engine enforces), use a real field with a contract.

## Public record

```nickel
{
  merge,                  # plain merge
  merge_with_check,       # merge + _check attached
  Service, Port, Volume, Network, Fragment,
  check,                  # alias for validation.check
  validation = { check },
  report = { services, ports },
  discover = {},          # placeholder
  version = "0.2.0",
}
```

Add new namespaces by extending the public record. Don't
add them as top-level let-bindings.


## Style

- **Append, don't refactor.** Existing let-bindings have
  their names for a reason (shadowing). Don't rename or
  restructure unless asked.
- **Comment the why, not the what.** Comments in the
  engine explain why a thing is the way it is. No narration
  of what the next line does.
- **Helpers in scripts/* are real tools.** If you change
  behavior, also update `tests/dummy_project_spec.sh` and
  run it.
- **The engine is the focus.** Don't add features to
  scripts that should live in the engine.

## Common commands

```bash
cd /code/nickel-compose

# Typecheck
nickel typecheck nickel-compose.ncl
NICKEL_IMPORT_PATH=/code/nickel-compose nickel typecheck <user-config.ncl>

# Run all tests
bash tests/_run.sh

# Run one spec
bash tests/schema_spec.sh -v

# Render
mise run render
# or
./scripts/to-compose.sh
```

## Known limitations (don't try to "fix" these)

- Value annotations `: Service = ...` break `nickel export`
  in nickel 1.17. The contracts are exposed as record
  *values*; runtime validation goes through `check`. Don't
  add value-level contract annotations.
- The `not_exported` annotation doesn't survive `nickel eval`
  serialization. **If the engine ever needs a field that the
  rendered YAML should ignore, name it with the `x-` prefix
  (e.g. `x-check` instead of `_check`).** Compose's spec
  reserves `x-*` as extension fields that are silently
  ignored by the runtime, so `podman compose config` won't
  complain. `nickel export` keeps `x-*` fields in the YAML
  output. This sidesteps the annotation lifecycle issue
  entirely. The current `_check` name is fine; the
  workaround for it lives in the wrapper. If a future
  field is added that doesn't need the wrapper's strip
  step, prefer `x-*` naming.
- `| optional` strips fields from the record. We don't use
  it on contracts. Don't start.
