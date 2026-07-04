# nickel-compose

Nickel-driven compose: import YAML fragments, merge with Compose
semantics, export a single `compose.yaml`.

## Why

Podman/Docker compose ships as YAML. Multi-fragment setups (root +
services + overlays) usually combine fragments via a picker script
or a colon-separated env var, but the merge semantics live in shell
scripts and YAML quirks (`!reset`, anchor merge, `${VAR:?}`). This
project:

- replaces the picker with a single `config.ncl`
- merges fragments in Nickel with the same semantics Compose uses
- auto-fills defaults (networks, restart, init) so fragments stay small
- synthesizes top-level `volumes:` and `networks:` from service references, so a root fragment is optional
- exports one `compose.yaml` that both `podman-compose` and
  `docker compose` auto-pick — no `-f` flag needed at deploy time

`NICKEL_COMPOSE` (the input list) is intentionally distinct from
`COMPOSE_FILE` (which compose tools reserve for the merged output).
Nickel-compose follows the convention `.yml` for input fragments
and `.yaml` for the rendered whole — never name a source fragment
`compose.yaml`, since that's reserved for the merged output that
both `podman-compose` and `docker compose` auto-pick.

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
./nickel-render.sh --config examples/podclaws/config.ncl --out compose.yaml
nickel export --format yaml examples/podclaws/config.ncl > compose.yaml
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
config.ncl  --[nickel export]-->  compose.yaml  --[podman compose]-->  containers
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

### Top-level synthesis

After merging, the engine scans every service's `volumes` and
`networks` fields. Named volumes and networks referenced by
services but not declared at the top level are synthesized as
`null` body. Bind mounts (`./path:`, `/abs:`, `${VAR}:`) are
skipped. The `default` network is skipped (compose handles it
implicitly). Any fragment can pre-declare a top-level entry with
full config (`driver`, `driver_opts`, etc.) — pre-declared
entries win over synthesis. So:

```nickel
# services/web.ncl — declares a service that references web-data
{
  services = {
    web = { image = "nginx:1.27", volumes = ["web-data:/var/www/html"] },
  },
}
```

renders to:

```yaml
services:
  web:
    volumes: ["web-data:/var/www/html"]
volumes:
  web-data: null   # synthesized from the service reference
```

To set NFS drivers or other options, add a top-level declaration
to any fragment — including inline in `services/web.ncl`:

```nickel
{
  services = { web = { volumes = ["web-data:/var/www/html"] } },
  volumes = { web-data = { driver = "local", driver_opts = { type = "nfs" } } },
}
```

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
  import "./base.yml",
  import "./services/web.yml",
  import "./services/db.yml",
  import "./overlays/dev.yml",
] in

build fragments
```

A root fragment is optional. If your services reference named
volumes and you don't need to set volume drivers or options,
skip `base.yml` entirely — the merge engine synthesizes
top-level declarations from service references.

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
│       ├── render             # render config to compose.yaml
│       └── test               # run the bash-spec test suite
├── nickel-render.sh           # shell wrapper (typecheck + export)
├── README.md
├── LICENSE
└── .gitignore
```

## License

MIT — see [LICENSE](./LICENSE).