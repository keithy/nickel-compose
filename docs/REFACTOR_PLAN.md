# Plan: bare-list `config.ncl` + `nickel-run` wrapper tool

## Goal

`config.ncl` becomes just a list of imports — no engine import, no merge call:

```nickel
[
  import "./base.yml",
  import "./services/web.yml",
]
```

The `use` script (and other verbs) wrap it with the engine + `merge_with_source`
at eval time. A new general-purpose tool, `nickel-run`, builds that wrapper
cleanly. `nickel-compose-run` is a thin convenience layer that pre-loads
`nickel-compose.ncl` as `compose`.

## Tool API

### `nickel-run` (pure, generic)

```
nickel-run [--keep] [--format ncl|json|yaml|yml|toml] [--out FILE]
           NAME=PATH [NAME=PATH...] -- EXPRESSION
```

- `NAME=PATH`: each path is checked for existence, then resolved to an
  absolute path. The extension is irrelevant — nickel's `import` handles
  `.ncl`/`.json`/`.yml`/`.yaml` natively.
- `--`: everything after is a single Nickel expression (collected as
  one string, regardless of internal whitespace).
- `EXPRESSION` is evaluated in a scope with two records:
  - `paths`: `{ NAME = "ABS_PATH", ... }` — string→string, the *path* of
    each input. Useful for `x-source` and similar provenance.
  - `run`: `{ NAME = (import "ABS_PATH"), ... }` — string→imported value.
- `--keep`: leave the temp wrapper file on disk for debugging.
- `--format`: output format. `ncl` (default) = raw `nickel eval` output.
  Others pipe through `nickel export --format ...`.
- `--out`: write to file instead of stdout.
- Pure: does NOT touch `NICKEL_IMPORT_PATH`. The user controls that.
- Errors clearly on missing files, unknown flags, malformed `NAME=PATH`,
  or missing `--`. No partial execution.

### `nickel-compose-run` (composer-specific convenience)

```
nickel-compose-run [--keep] [--format ...] [--out FILE]
                   NAME=PATH [NAME=PATH...] -- EXPRESSION
```

- Forwards to `nickel-run` with `compose="$ENGINE"` prepended so the
  user can write `compose.foo paths.bar` without knowing the engine path.
- Sets `NICKEL_IMPORT_PATH` to the engine's parent dir (so `nickel-compose.ncl`
  can find its own sub-imports, if any are added later).
- The engine is resolved via the same search order as today:
  `$CWD/nickel-compose/nickel-compose.ncl`, `$CWD/nickel-compose.ncl`,
  `$SCRIPT_DIR/../nickel-compose.ncl`, `$NICKEL_COMPOSE_ENGINE`.

### `nickel-compose.sh use`

Now calls `nickel-compose-run fragments="$IN" -- 'compose.merge_with_source fragments paths.fragments'`.

After eval, still does the `nickel export --format yaml` to write
`compose.yaml` and the x-check readback (unchanged).

## Files to change

### New
- `nickel-compose/scripts/nickel-run.sh` — the pure wrapper tool.
- `nickel-compose/scripts/nickel-compose-run.sh` — convenience wrapper.

### Modified
- `nickel-compose/scripts/to-compose.sh` — drop the eval-the-config-
  directly step; instead call `nickel-compose-run` to build the wrapper.
  Engine-location search and NICKEL_IMPORT_PATH setup moves to
  `nickel-compose-run`.
- `nickel-compose/scripts/from-nickel-compose.sh` — the generated
  `config.ncl` becomes a bare list (no `let composer = ...`, no
  `composer.merge_with_check`).
- `nickel-compose.sh` — `verb_report` calls `nickel-run` instead of
  inlining the wrapper.
- `nickel-compose/AGENTS.md` — update to reflect new file shape.
- `nickel-compose/docs/schema.md` — update example config.ncl.

### Converted to bare list
- `nickel-compose/examples/dummy-project/config.ncl`
- `nickel-compose/examples/dummy-project/config_ncl.ncl`
- `nickel-compose/examples/dummy-project/config_mixed.ncl`
- `nickel-compose/examples/dummy-project/config_no_base.ncl`
- `nickel-compose/examples/podclaws/config.ncl`
- `/code/podclaws/config/example.ncl`

## Tests

- Add `tests/nickel_run_spec.sh`: smoke test the standalone tool with
  `.ncl`/`.json`/`.yml` inputs, all output formats, `--keep`, missing-file
  errors, missing-`--` errors.
- Update `tests/dummy_project_spec.sh`: the in-spec `out/.driver-test.ncl`
  fixture is hand-written and imports the engine. Either keep it (still
  works) or replace with a bare list form. Decision: leave it; it's a
  legitimate use case for advanced users.
- Verify `tests/podclaws_spec.sh` still passes (depends on the refactored
  `/code/podclaws/config/example.ncl`).
- Run `tests/_run.sh` and confirm 257+ passing.

## Out of scope (deferred)

- `nickel-compose-use` (a third convenience wrapper that pre-bakes the
  standard `compose.merge_with_source` expression). Not needed for this
  refactor; the user can write the expression once in `use`.
- Removing `composer.merge` / `composer.merge_with_check` from the engine.
  They stay for advanced users (the driver-test fixture uses `merge`).
- `nickel-compose.sh report` could later be refactored to a dedicated
  `nickel-compose-report` script, but for now the in-shell wrapper is
  fine.

## Risks

- The user-facing config.ncl shape changes. Any external project that
  reads podclaws's `config/example.ncl` and copies the `let composer = ...`
  pattern will need updating. Mitigation: it's all internal — the example
  is the reference.
- The from-wrapper test compares byte-equality of the two-step flow.
  The shape of the generated config.ncl changes (bare list), but the
  YAML output must remain byte-equal. The contract is the YAML, not the
  config.ncl.
- The `report source` verb depends on the engine's `x-source` field.
  After the refactor, `use` still calls `merge_with_source`, so the
  field is still set. No behaviour change.

## Order of work

1. Write `nickel-run.sh` and test it standalone (with a small smoke test).
2. Write `nickel-compose-run.sh`.
3. Refactor `to-compose.sh` to use `nickel-compose-run`. Verify `use`
   works end-to-end on `examples/dummy-project/`.
4. Refactor `verb_report` in `nickel-compose.sh` to use `nickel-run`.
5. Update `from-nickel-compose.sh` to generate a bare-list config.ncl.
6. Convert all the example `config.ncl` files to bare lists.
7. Update `/code/podclaws/config/example.ncl`.
8. Run full test suite. Fix failures.
9. Commit, get explicit approval before push.
