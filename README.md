# nickel-compose

Nickel-driven compose: import YAML fragments, merge with Compose
semantics, export a single `compose.yml`.

## Why

Podman/Docker compose ships as YAML. Multi-fragment setups (root +
services + overlays) usually combine fragments via a picker script
or a colon-separated env var, but the merge semantics live in shell
scripts and YAML quirks (`!reset`, anchor merge, `${VAR:?}`). This
project:

- replaces the picker with a single `config.ncl`
- merges fragments in Nickel with the same semantics Compose uses
- auto-fills defaults (networks, restart, init) so fragments stay small
- exports one `compose.yml` that both `podman-compose` and
  `docker compose` auto-pick — no `-f` flag needed at deploy time

`COMPOSE_FRAGMENTS` (the input list) is intentionally distinct from
`COMPOSE_FILE` (which compose tools reserve for the merged output).
A source fragment named `compose.yml` would collide with the output —
rename it (e.g. to `base.yml`).

## Install

```bash
git clone https://github.com/keithy/nickel-compose.git
cd nickel-compose
mise trust         # trust mise/config.toml
mise install       # install nickel + jq
```

## Usage

With mise tasks (recommended):

```bash
mise run check                       # typecheck the merge engine
mise run test                        # run the bash-spec test suite
mise run render                      # render examples/podclaws/config.ncl
mise run render -- config=path out=path   # render a custom config
```

Or directly:

```bash
./nickel-render.sh --config examples/podclaws/config.ncl --out compose.yml
nickel export --format yaml examples/podclaws/config.ncl > compose.yml
./tests/merge_spec.sh                 # bash-spec test runner
```

The test suite uses [bash-spec 2.1](https://github.com/keithy/) (vendored
under `tests/lib/`). Run `./tests/merge_spec.sh` to see the
`describe` / `context` / `it` / `should_succeed` style output.

### Golden-file testing

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

## How it works

```
config.ncl  --[nickel export]-->  compose.yml  --[podman compose]-->  containers
   |
   +-- imports YAML fragments
   +-- applies defaults per service
   +-- merges fragments with Compose semantics
```

The merge engine (`lib/merge.ncl`) is a single function that takes a
list of fragments and returns a merged Compose record. `config.ncl`
calls it with the fragments it has selected.

### Merge semantics

For each field in the later fragment (`b`):

| Type of `b` | Type of `a` | Field in `array_fields`? | Action |
|-------------|-------------|--------------------------|--------|
| scalar | scalar | n/a | `b` wins |
| array | array | yes | concat (`a @ b`) |
| array | array | no | `b` wins |
| record | record | n/a | recurse |
| anything | absent | n/a | insert from `b` |

`array_fields` defaults to:
`environment`, `volumes`, `ports`, `extra_hosts`, `tmpfs`,
`env_file`, `cap_add`, `cap_drop`, `security_opt`.

`services`, `volumes`, `networks` are unioned across fragments —
later wins on key collision.

### Defaults

Each service gets these defaults filled in if missing:

```nickel
{
  networks = ["default"],
  restart = "unless-stopped",
  init = false,
}
```

If a fragment already sets `networks`, that wins. Override the
defaults in `lib/merge.ncl`'s `default_service` record.

## Writing a config

```nickel
let build = import "../lib/merge.ncl" in

let fragments = [
  import "./compose.yml",
  import "./services/web.yml",
  import "./services/db.yml",
  import "./overlays/dev.yml",
] in

build fragments
```

## What's not covered yet

- **Per-fragment typecheck** — contracts work in `nickel typecheck`
  but break `nickel export`. Needs a separate `check.ncl`.
- **Cross-fragment validation** — `service.redis.yml` references
  `redis`, but nothing enforces that another file declares it.
  podman-compose catches this at `up` time.
- **Non-array field overrides** — Compose's `${VAR:?msg}` is preserved
  through round-trip. The merge engine doesn't validate required envs.

## Status

Verified end-to-end with nickel 1.17.0 and podman-compose 1.6.0.
Test suite covers env concat, volume concat, default fill, and full
round-trip through podman-compose.

## Layout

```
nickel-compose/
├── lib/
│   └── merge.ncl              # merge engine (single function)
├── examples/
│   ├── dummy-project/         # self-contained first-time-user example
│   └── podclaws/              # example using real podclaws fragments
├── tests/
│   ├── merge.ncl              # synthetic merge fixture
│   ├── merge_spec.sh          # bash-spec 2.1 test runner
│   ├── lib/
│   │   └── bash-spec.sh       # vendored bash-spec 2.1
│   ├── out/                   # rendered outputs (gitignored)
│   └── expected/              # golden snapshots (committed)
├── mise/
│   ├── config.toml            # tools (nickel, jq) + task config
│   └── tasks/
│       ├── check              # typecheck the merge engine
│       ├── render             # render config to compose.yml
│       └── test               # run the bash-spec test suite
├── nickel-render.sh           # shell wrapper (typecheck + export)
├── README.md
├── LICENSE
└── .gitignore
```

## License

MIT — see [LICENSE](./LICENSE).