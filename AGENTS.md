# Agent Instructions for nickel-compose

This file applies to AI agents working in the nickel-compose
repo. Generic agent behavior rules (Pre-Session Checklist,
Plan First, Anti-Arrogance Clause) live in the project-level
`/code/AGENTS.md` and are not repeated here.

## Hard rules

- **Never `git reset --hard`, `git push --force`, or `git
  commit --amend` without explicit user instruction.** A
  `--hard` reset in this session already lost work. Reflog
  exists, but trust the user, not the reflog.
- **Commit incrementally.** After every meaningful change
  (contract, function, script, test), commit. Even WIP on a
  `wip/` branch is better than uncommitted work.
- **Tests must stay green.** `bash tests/_run.sh` should
  report 256+/256+ before any commit. If a test breaks, fix
  it before committing.

## Recovery

If the working tree gets clobbered, recover from a zrepl
snapshot:

```bash
bash /code/zepl/recover.sh latest   # mount most recent
# ... copy files back, commit them ...
bash /code/zepl/tidy-up.sh --force  # clean up
```

zrepl takes snapshots every 15 minutes (see
`/code/zepl/zrepl.yml`). Worst-case loss window is 15
minutes of uncommitted work.

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

## Test conventions

- Tests are bash scripts in `tests/*_spec.sh` using the
  vendored `tests/lib/bash-spec.sh` (bash-spec 2.1).
- `tests/_run.sh` runs them all in order.
- Each spec runs in `cd "$(dirname "$0")"` — paths in the
  test body are relative to the spec file, not the project.
- NICKEL_IMPORT_PATH is set per-spec to the project root
  so fixtures can use `import "nickel-compose.ncl"` without
  a path prefix.
- Golden files in `tests/expected/` are byte-equality
  targets. Set `INIT=true bash tests/_run.sh` to regenerate.
- `tests/out/` is gitignored. Tests clean it at start.
- **Baseline**: 256/256 passing. Don't break this count.

Common assertion patterns:
- `run nickel export --format json <file> > <out>` then
  `expect_jq <out> '.foo.bar' to_be "expected"`
- `run bash scripts/something.sh` then `should_succeed` /
  `should_fail`
- `expect <file> to_exist` for file existence
- `expect_no_diff <gen> <expected>` for golden-file equality

For new tests, follow the pattern in `tests/conditionals_spec.sh`
or `tests/schema_spec.sh`. They're the cleanest examples.

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
  serialization. The wrapper handles the strip. Don't try
  to move the strip into the engine.
- `| optional` strips fields from the record. We don't use
  it on contracts. Don't start.
