# nickel-compose

Nickel-driven compose: import YAML fragments, merge with Compose
semantics, export a single `podman-compose.yml`.

## Why

Podman/Docker compose ships as YAML. Multi-fragment setups (root +
services + overlays) work via `COMPOSE_FILE=frag1:frag2:...`, but the
selector logic and merge semantics live in shell scripts and YAML
quirks (`!reset`, anchor merge, `${VAR:?}`). This project:

- replaces the picker with a single `config.ncl`
- merges fragments in Nickel with the same semantics Compose uses
- auto-fills defaults (networks, restart, init) so fragments stay small
- exports one `podman-compose.yml` that podman-compose picks up by
  convention (no `COMPOSE_FILE` needed)

## Requirements

- [nickel](https://nickel-lang.org/) 1.17+ (mise: `aqua:nickel-lang/nickel`)
- `jq` for the test suite
- `podman-compose` (only for the podclaws example end-to-end check)

## Usage

```bash
# Render a config to podman-compose.yml:
./nickel-render.sh --config examples/podclaws/config.ncl

# Or directly:
nickel export --format yaml examples/podclaws/config.ncl > podman-compose.yml

# Run the test suite:
./tests/run.sh
```

## How it works

```
config.ncl  --[nickel export]-->  podman-compose.yml  --[podman compose]-->  containers
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
let build = import "nickel-compose/lib/merge.ncl" in

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

## License

See [LICENSE](./LICENSE).