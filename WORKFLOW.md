# WORKFLOW — The Central Config and Migration Paths

## The central workflow

A deployment in nickel-compose is one `.ncl` file that renders to
one compose file. The workflow is:

```
compose.ncl   ──[nickel export]──>   compose.yml   ──[podman compose]──>   containers
prod.ncl      ──[nickel export]──>   prod.yml      ──[podman compose]──>   containers
staging.ncl   ──[nickel export]──>   staging.yml   ──[podman compose]──>   containers
```

Each `.ncl` is a complete deployment description. Comments live
in the `.ncl`. The YAML is a build artifact, auto-picked by
`podman-compose` / `docker compose`.

To create a new deployment:

1. Write `compose.ncl` (or any name) with the typed `Compose`
   record.
2. Run `nickel export --format yaml compose.ncl > compose.yml`.
3. Run `podman-compose up -d`.

That's the core. Everything else is migration tooling to get
existing projects to this point without forcing a big-bang
rewrite.

## The `.ncl` file

The user's `.ncl` file has the structure of a typed record. It
imports the merge engine and lists fragments (or inlines them):

```nickel
let build = import "nickel-compose/lib/merge.ncl" in

let fragments = [
  # Root: networks + named volumes
  {
    networks = { default = { driver = "bridge" } },
    volumes = { "web-data" = null },
  },

  # Services
  {
    services = {
      web = {
        image = "nginx:1.27",
        ports = ["8080:80"],
        # ...
      },
      db = {
        image = "postgres:16-alpine",
        # ...
      },
    },
  },

  # Local dev overlay
  {
    services = {
      db = { ports = ["5432:5432"] },
      redis = { image = "redis:7-alpine" },
  },
] in

build fragments
```

The `fragments` list can also import YAML files (decomposed
mode). The merge engine doesn't care whether fragments are
inline records or `import`ed YAML.

## Migration workflows

Existing projects have one or more of these env vars set:

- `COMPOSE_FILE` — the conventional compose list (colon-separated
  YAML files). Set by docker, podman, mise, shell rc, `.env`.
- `COMPOSE_SERVICES` — services definition. Used in some
  projects as a convention.
- `COMPOSE_OVERLAYS` — overlay fragments. Used in some projects
  for dev/test/prod patches.

The migration wrapper accepts any combination of these and
combines them into one fragment list passed to the merge
engine. The wrapper itself doesn't render — that's the user's
job via `nickel export`.

### Wrapper contract

`NICKEL_COMPOSE` is the orchestrator. It accepts a colon-separated
list of env-var names whose values are themselves colon-separated
fragment lists:

```
NICKEL_COMPOSE=$COMPOSE_SERVICES:$COMPOSE_OVERLAYS:$COMPOSE_FILE
```

The wrapper reads each named env var, splits on `:`, and
produces a merged fragment list. Order is preserved: services
first, then overlays, then any legacy `COMPOSE_FILE` fragments
last (so they can override earlier definitions if needed).

### Why this shape

- **Each env var keeps its existing role.** A project that uses
  `COMPOSE_FILE` doesn't have to rename anything to use
  nickel-compose. It can set `NICKEL_COMPOSE=$COMPOSE_FILE` and
  nothing else changes.
- **Migrate incrementally.** Move services into `COMPOSE_SERVICES`
  one at a time. Then overlays into `COMPOSE_OVERLAYS`. Each
  step is a no-op for the runtime — same fragments, same output.
- **The `.ncl` file is the end state.** Once everything's in
  three env vars, the user can `freeze` the migration by writing
  a single `compose.ncl` that imports the same fragments.
  `NICKEL_COMPOSE` becomes unused; the `.ncl` is the source of
  truth.

### Migration steps (incremental)

**Stage 0: existing project, `COMPOSE_FILE` only**

```bash
# .env or mise.toml
COMPOSE_FILE=services/web.yml:services/db.yml:overlays/dev.yml
NICKEL_COMPOSE=$COMPOSE_FILE
```

The wrapper reads `COMPOSE_FILE` directly. No behavior change.

**Stage 1: split services from overlays**

```bash
COMPOSE_SERVICES=services/web.yml:services/db.yml
COMPOSE_OVERLAYS=overlays/dev.yml
COMPOSE_FILE=base.yml   # root fragment only
NICKEL_COMPOSE=$COMPOSE_SERVICES:$COMPOSE_OVERLAYS:$COMPOSE_FILE
```

The wrapper reads all three. Order: services, overlays, file.
Same merged output.

**Stage 2: freeze into compose.ncl**

```nickel
# compose.ncl
let build = import "nickel-compose/lib/merge.ncl" in

let fragments = [
  import "base.yml",
  import "services/web.yml",
  import "services/db.yml",
  import "overlays/dev.yml",
] in

build fragments
```

Drop the env vars. `nickel export --format yaml compose.ncl >
compose.yml` is now the build step. The wrapper is no longer
used; `NICKEL_COMPOSE` is removed from the environment.

**Stage 3: optional — convert fragments to inline records**

Convert `services/web.yml` to a Nickel record literal. Inline
comments. Single `compose.ncl` becomes the whole deployment.

---

## What this gives the user

- **Stage 0** is zero-work. Set `NICKEL_COMPOSE=$COMPOSE_FILE`
  and the existing project gains typecheck.
- **Stage 1** is mechanical. Move files between env vars when
  convenient.
- **Stage 2** is the destination. One `.ncl` file. Typecheck
  catches typos before any container starts.
- **Stage 3** is optional. Most projects stay at Stage 2.

The end state is "edit `compose.ncl`, run `nickel export`, run
`podman-compose up`." No env vars, no bash picker, no
`!reset`, no `base.yml` workaround.

## What this gives the AI

A future LLM that needs to "run a pod of containers" can write
`compose.ncl` directly. The mental model is the typed record,
not a YAML dialect. Same model works for Kubernetes, Helm, or
any other renderer added later — see DESIGN.md.

For migration, the LLM can:
- read existing env vars and project files
- write `compose.ncl` that imports the same fragments
- verify the output is byte-identical to the legacy render
- replace the env vars with the `.ncl`

That's an abstraction bump: the same deployment description,
expressed at a higher level, validated at write-time, with no
runtime change.