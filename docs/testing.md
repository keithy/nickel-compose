# testing

The test suite uses [bash-spec 2.1](https://github.com/keithy/) (vendored
under `tests/lib/`).

## Running the tests

```bash
mise run test                  # run the bash-spec test suite
./tests/_run.sh                # equivalent, without mise
./tests/_run.sh -v             # verbose: dump each spec's output
```

`_run.sh` discovers `tests/*_spec.sh` and runs each. Per-spec and
aggregate pass/fail counts are printed at the end.

## Spec layout

| Spec | Coverage |
|------|----------|
| `typecheck_spec.sh` | typechecks the merge engine and example configs |
| `merge_spec.sh` | synthetic two-fragment fixture; array concat, default fill, top-level union, overlay-wins |
| `conditionals_spec.sh` | if_present / if_absent conditional patches |
| `dummy_project_spec.sh` | end-to-end against `examples/dummy-project/`, including all four `config*.ncl` configs and the NICKEL_COMPOSE wrapper |
| `podclaws_spec.sh` | real-world fragment patterns (${VAR} interpolation, bind mounts, short-form refs, env_file as object, command as array) |

## Golden-file testing

Rendered outputs go to `tests/out/` (gitignored). Snapshots of the
correct output live in `tests/expected/` (committed). Each test
asserts that the rendered file matches its expected snapshot.

To regenerate snapshots after intentional changes:

```bash
INIT=true mise run test
git add tests/expected/
```

In normal runs (no `INIT`), tests fail if `tests/out/` and
`tests/expected/` differ.

## Adding tests

For new merge-engine behavior, add a fixture in `tests/fixtures/`
and assertions in the appropriate `tests/*_spec.sh`. For
conditional-patch cases, see `tests/fixtures/conditionals/`
for examples. The pattern is:

1. Create a small `.ncl` fixture declaring a fragment with the
   feature under test.
2. In the spec, wrap the fixture in a `build [...]` call (so the
   engine actually processes it, not just outputs the raw
   record).
3. Assert the rendered JSON/YAML matches expectations using
   `expect_jq` or `expect_no_diff`.