# dummy-project — first-time user example

A self-contained example showing how to add nickel-compose to an
existing podman/docker-compose project. Compose fragments live here;
the wrapper that drives the merge from `$NICKEL_COMPOSE` lives at
the nickel-compose repo root (`../../scripts/`).

## What's here

```
dummy-project/
├── base.yml                # root: networks + named volumes (optional — see config_no_base.ncl)
├── base.ncl                # Nickel equivalent of base.yml
├── services/
│   ├── web.yml              # web service skeleton
│   ├── web.ncl              # Nickel equivalent
│   ├── db.yml               # database service skeleton
│   └── db.ncl               # Nickel equivalent
├── overlays/
│   ├── dev.yml              # local development overlay (adds redis, exposes db)
│   └── dev.ncl              # Nickel equivalent
├── config.ncl               # all-YAML entry point (Stage 0) — uses merge_with_check
├── config_ncl.ncl           # all-Nickel entry point (Stage 3) — with schema check
├── config_with_check.ncl    # explicit composer.check call (Stage 3+)
├── config_mixed.ncl         # partial migration demo (Stage 2)
├── config_no_base.ncl       # no root fragment — engine synthesizes from services
└── mise/
    └── config.toml          # tools + cd hook + task includes
```

The wrapper `from-nickel-compose.sh` lives at the nickel-compose
repo root (`../../scripts/`). The mise cd hook in this directory
points there.

The root fragment is named `base.yml`, not `compose.yaml`, because
`compose.yaml` is reserved as the merged output filename (auto-picked
by podman-compose and docker compose). Naming the source `base.yml`
avoids any collision.

**You don't actually need a base fragment.** The merge engine scans
service volume and network references and synthesizes top-level
declarations. See `config_no_base.ncl` for the demo.

## Try it first — Stage 0 (zero work)

If you already maintain a `COMPOSE_FILE` env var (the conventional
colon-separated YAML list), try nickel-compose in **two lines**, no
env-var rename:

```bash
# in your existing setup (shell rc, .env, mise [env], wherever):
export COMPOSE_FILE="base.yml:services/web.yml:services/db.yml:overlays/dev.yml"
export NICKEL_COMPOSE='$COMPOSE_FILE'

# render via the wrapper:
../../scripts/from-nickel-compose.sh
```

What happens:

1. The wrapper reads `NICKEL_COMPOSE`, sees `$COMPOSE_FILE`, and
   indirect-expands it to the literal fragment list.
2. The wrapper generates a temp `compose.ncl` with literal `import`
   lines for each fragment.
3. `nickel export` runs against that temp file, writing `compose.yaml`.

Your existing `COMPOSE_FILE` is **untouched**. If you `unset
NICKEL_COMPOSE`, you're back to whatever your previous workflow was.
This is a non-destructive preview — see the result, then decide
whether to migrate further.

## Two ways to drive the merge

### Option A: literal fragment list (config.ncl)

`config.ncl` lists fragments by name. To add or remove a fragment,
edit the `fragments` array:

```nickel
let fragments = [
  import "./base.yml",
  import "./services/web.yml",
  import "./services/db.yml",
  import "./overlays/dev.yml",
] in
```

Order matters: later fragments override scalars and concat arrays.
This is the simplest setup — no environment variable required.

### Option B: NICKEL_COMPOSE-driven (scripts/from-nickel-compose.sh)

If you already maintain a list of fragments in env vars (in `.env`,
`.bashrc`, mise `[env]`, etc.), the wrapper reads `NICKEL_COMPOSE`
and renders `compose.yaml`. `NICKEL_COMPOSE` is a colon-separated
list where each token is either a literal fragment path or a `$VAR`
reference (which expands to another colon-separated list). Mixed
forms are allowed:

```bash
# Stage 0 — single env var holding the full list
export COMPOSE_FILE="base.yml:services/web.yml:services/db.yml:overlays/dev.yml"
NICKEL_COMPOSE='$COMPOSE_FILE' ../../scripts/from-nickel-compose.sh

# Stage 1 — split into services / overlays / file
export COMPOSE_SERVICES="services/web.yml:services/db.yml"
export COMPOSE_OVERLAYS="overlays/dev.yml"
export COMPOSE_FILE="base.yml"
NICKEL_COMPOSE='$COMPOSE_SERVICES:$COMPOSE_OVERLAYS:$COMPOSE_FILE' \
  ../../scripts/from-nickel-compose.sh

# Literal-only — no env-var indirection at all
NICKEL_COMPOSE="base.yml:services/web.yml:services/db.yml:overlays/dev.yml" \
  ../../scripts/from-nickel-compose.sh
```

Internally the wrapper generates a temporary `config.ncl` with literal
imports, runs `nickel export`, and cleans up. Why the temp file?
Nickel 1.17 requires `import` paths to be literals at parse time —
runtime paths aren't supported. The wrapper bridges that gap.

When you run `podman-compose up`, podman-compose reads the merged
`compose.yaml` (the conventional name) — no `COMPOSE_FILE` env
needed at runtime, since the merged file is the only input.

See [WORKFLOW.md](../../WORKFLOW.md) for the full migration story
from existing `COMPOSE_FILE`-style projects.

## Try it

```bash
cd examples/dummy-project
mise trust
mise install
```

Then either:

```bash
# Option A — direct
mise run render             # uses ./config.ncl
podman-compose config       # validates
```

or:

```bash
# Option B — NICKEL_COMPOSE-driven
export COMPOSE_FILE="base.yml:services/web.yml:services/db.yml:overlays/dev.yml"
NICKEL_COMPOSE='$COMPOSE_FILE' ../../scripts/from-nickel-compose.sh
podman-compose config
```

## What gets merged

Both options produce the same `compose.yaml`. Render it and look:

- `db` service: image + env from `db.yml`, plus the `5432:5432` port
  from `overlays/dev.yml`. Defaults `networks`/`restart`/`init`
  filled in.
- `web` service: env from `web.yml` + `REDIS_HOST`/`REDIS_PORT`
  from `overlays/dev.yml` (concat). Ports and depends_on from
  `web.yml`.
- `redis` service: added by `overlays/dev.yml` (sibling service).
- Named volumes `web-data`, `db-data`: declared in `compose.yaml`.

## The mise cd hook

To keep `compose.yaml` fresh without running anything manually,
wire the wrapper into your project's `mise.toml`:

```toml
[hooks]
cd = "QUIET=true $NC_ROOT/scripts/from-nickel-compose.sh"
```

(where `$NC_ROOT` is the path to your nickel-compose install —
submodule, vendor copy, or `mise x --` invocation).

Now every `cd` into the project regenerates `compose.yaml` from
your current `NICKEL_COMPOSE`.

## Migrating your own project

1. Add nickel-compose as a submodule (or vendor it):
   ```bash
   git submodule add https://github.com/keithy/nickel-compose.git nickel-compose
   ```
2. Copy `config.ncl` (Option A) into your project, OR set up
   `NICKEL_COMPOSE` in your shell / `.env` / mise `[env]` (Option B)
   and reference `nickel-compose/scripts/from-nickel-compose.sh`
   from a cd hook or `mise run render`.
3. Add the cd hook to your `mise.toml`.
4. `mise trust && mise install`
5. `cd` into the project — `compose.yaml` appears.

If you already have a fragment list set in `.env` or `.bashrc` as
`COMPOSE_FILE`, set `NICKEL_COMPOSE='$COMPOSE_FILE'` (Stage 0) and
the wrapper does the rest. No env var rename needed.

## Troubleshooting

- **`nickel: command not found` on cd** — run `mise install` once
  on first checkout.
- **`file not found` from nickel export** — typo in `config.ncl`'s
  `fragments` list, or a path in `NICKEL_COMPOSE` that doesn't exist.
  Paths in `config.ncl` are relative to the file; paths in
  `NICKEL_COMPOSE` are relative to cwd.
- **`output path ... is also a fragment`** — your fragment list
  includes a file with the same name as the output (default
  `compose.yaml`). Either rename the source fragment (e.g. to
  `base.yml`) or pass `--out merged-compose.yaml` to the wrapper.
- **`podman-compose config` rejects output** — usually a malformed
  `${VAR}` in a fragment. Comment out fragments one at a time to find
  the offender.
- **Want to update golden test snapshots** — see top-level
  `tests/_run.sh`; run `INIT=true ./tests/_run.sh` from the repo root.

## Verified

This dummy project is exercised by the bash-spec test suite at the
repo root (`tests/dummy_project_spec.sh`). 19 assertions cover
service union, env concat, port merge, named volumes,
podman-compose validation, and four `NICKEL_COMPOSE` wrapper variants
(Stage 0, Stage 1, mixed literal/env-var refs, and literal-only).