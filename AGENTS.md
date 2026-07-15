# Agent Instructions for nickel-compose

> This file is local to the nickel-compose repo. It tells AI
> agents (Crush, Claude, etc.) what's specific about working
> here, beyond the generic project-level rules at
> `/code/AGENTS.md`.

## What this repo is

nickel-compose is a merge engine for docker-compose fragments,
written in Nickel. Single file (`nickel-compose.ncl`) plus
wrapper scripts, tests, and docs. See `README.md`,
`docs/design.md`, `docs/schema.md`, `docs/workflow.md`,
`docs/testing.md` for the actual project.

The engine is the focus. Scripts and examples are there to
exercise the engine. Don't add features to scripts that
should live in the engine.

## Hard rules

- **Never use `git reset --hard`, `git push --force`, or
  `git commit --amend` without explicit user instruction.** A
  `--hard` reset in this session already lost work. Reflog
  exists, but trust the user, not the reflog.
- **Commit incrementally.** After every meaningful change
  (contract, function, script, test), commit. Even WIP on a
  `wip/` branch is better than uncommitted work.
- **Tests must stay green.** `bash tests/_run.sh` should
  report 256/256 (or more) before any commit. If you break
  a test, fix it before committing.

## Engine mechanics

- The engine is `nickel-compose.ncl`, ~660 lines. Read it
  before editing.
- Field names in the public record (e.g. `Service`, `check`)
  shadow let-bindings of the same name at evaluation time.
  Inner bindings are named `<thing>_schema` / `run_<thing>`
  to avoid this. Don't rename them back.
- Contracts are records with field-level `| doc "..."` and
  `| default = ...`. Order matters: `| doc` before `| default`.
  `| optional` strips the field from the record entirely
  (breaks `record.fields` introspection) — don't use it.
- `_check | not_exported` annotations survive in source code
  but get stripped by `nickel eval` serialization. The wrapper
  (`scripts/to-compose.sh`) handles the strip with a small
  helper that destructures the record and re-emits it.

## Working with snapshots / recovery

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

## Tests

`tests/_run.sh` runs all the bash-spec files. Each spec
(`*_spec.sh`) is one context. Specs are bash scripts using
the vendored `tests/lib/bash-spec.sh`. Run a single spec
with `bash tests/<name>_spec.sh`.

Common assertions:
- `should_succeed` / `should_fail` — exit code of the
  previous `run` or shell command
- `expect_jq` — jq query against a JSON file
- `expect_no_diff` — byte-equality of two files
- `expect <file> to_exist` — file existence

## Editing rules specific to this repo

- `nickel-compose.ncl` — append new features, don't refactor
  existing code unless asked. The let-bindings are
  deliberately named (e.g. `service_schema` not `Service`)
  to avoid shadowing in the public record.
- `scripts/*.sh` — these are real production tools. If
  changing behavior, also update `tests/dummy_project_spec.sh`
  and run it.
- `docs/*.md` — these explain *why*. Update when behavior
  changes; don't add new docs without a corresponding
  feature.
- `tests/fixtures/` — synthetic fragments for engine tests.
  Don't add real-world fragments here; those belong in
  `examples/`.
- `examples/` — first-time-user demos. Should be copy-paste
  runnable. Test them by running `cd examples/dummy-project
  && mise run render` after changes.
