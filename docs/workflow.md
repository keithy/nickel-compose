# WORKFLOW — Config Generation and Migration Paths

## The central workflow

A deployment in nickel-compose is one `config.ncl` file that
renders to one `compose.yaml`. The flow is:

```
config.ncl   ──[nickel-compose.sh use]──>   compose.yaml   ──[podman compose]──>   containers
```

`compose.yaml` is the merged record — auto-picked by
`podman-compose` and `docker compose` at deploy time, so no `-f`
flag is needed.

To create a new deployment:

1. Generate `config.ncl` (with `dc2nc.sh`, or write it by hand).
2. Run `nickel-compose.sh use`.
3. Run `podman-compose up -d`.

That's the core. Everything else is migration tooling to get
existing projects to this point without forcing a big-bang rewrite.

## The `config.ncl` file

The user's `config.ncl` is a bare list of fragment imports. The
dispatcher (`nickel-compose.sh use`) wraps it with the merge
engine and calls `composer.merge_with_source` at eval time — no
engine import or merge call needed in the file itself:

```nickel
# config.ncl
[
  import "./base.yml",
  import "./services/web.yml",
  import "./services/db.yml",
  import "./overlays/dev.yml",
]
```

Order matters: later fragments override scalars and concat arrays.

## Generating config.ncl with dc2nc.sh

`scripts/dc2nc.sh` is the recommended way to build `config.ncl`.
It reads a list of fragment paths on stdin (one per line) and
writes a bare-list `config.ncl` on stdout. All candidates appear
as commented examples; the picked subset (via `--pick PATH`,
repeatable, or as bare positionals) is uncommented and live:

```bash
find . \( -name '*.yml' -o -name '*.ncl' \) \
  | scripts/dc2nc.sh --pick base.yml \
                     --pick services/web.yml \
                     --pick services/db.yml \
                     --pick overlays/dev.yml \
  > config.ncl
```

Output (written to `config.ncl`):

```nickel
# dc2nc.sh output — bare-list config.ncl
# Uncomment a line to enable a fragment. The picked subset is live.
[
  import "./base.yml",
  import "./services/web.yml",
  # import "./services/db.yml",
  # import "./overlays/dev.yml",
]
```

So the workflow is: pipe fragments in, pick what you want, save
the result as `config.ncl`. Edit the file by hand later to add or
remove fragments — it's just a plain list.

`--find-all` runs `find . \( -name '*.yml' -o -name '*.ncl' \)`
itself, so `dc2nc.sh --find-all --pick base.yml` works without a
pipe. Same basename in different directories is fine — dc2nc
matches by relative path, so `agent/base.yml` and
`database/base.yml` are unambiguously distinct.

## NICKEL_COMPOSE: the default config path

`NICKEL_COMPOSE` is a single env var pointing at a `config.ncl`.
When mise/direnv/CD-hook sets it, bare `nickel-compose.sh use`
resolves to that config without any args:

```toml
# mise.toml
[env]
NICKEL_COMPOSE = "./config.ncl"

[hooks]
postcd = "nickel-compose.sh use"
```

An explicit `use config.ncl` always wins over `$NICKEL_COMPOSE`,
so the env var is purely a default.

## Migration workflows

Existing projects often have a `COMPOSE_FILE` env var set (the
conventional colon-separated YAML list). The migration story is
about reaching the `config.ncl`-driven workflow without forcing a
big-bang rewrite.

### Stage 0: existing project, `COMPOSE_FILE` only

If your project already sets `COMPOSE_FILE`, try nickel-compose
in **one line** — keep `COMPOSE_FILE` and point a new var at it:

```bash
# .env or mise.toml
COMPOSE_FILE=services/web.yml:services/db.yml:overlays/dev.yml
NICKEL_COMPOSE=./config.ncl
```

Then in the project dir, manually generate `config.ncl` once:

```bash
# convert the existing COMPOSE_FILE into a config.ncl:
find . \( -name '*.yml' -o -name '*.ncl' \) \
  | scripts/dc2nc.sh $(echo "$COMPOSE_FILE" | tr ':' '\n') \
  > config.ncl
```

`NICKEL_COMPOSE` points at `config.ncl`; bare `nickel-compose.sh
use` renders it. The dispatcher doesn't read `COMPOSE_FILE` — the
shape is "config.ncl is the source of truth" from day one.

### Stage 1: split services from overlays

Move fragments into per-purpose env vars (or just edit
`config.ncl` directly — it's a plain list):

```bash
# .env or mise.toml
COMPOSE_SERVICES=services/web.yml:services/db.yml
COMPOSE_OVERLAYS=overlays/dev.yml
COMPOSE_FILE=base.yml
```

When you regenerate `config.ncl`, pipe all three lists through
dc2nc.sh:

```bash
printf '%s\n' \
  $(echo "$COMPOSE_SERVICES" | tr ':' '\n') \
  $(echo "$COMPOSE_OVERLAYS" | tr ':' '\n') \
  $(echo "$COMPOSE_FILE" | tr ':' '\n') \
  | dc2nc.sh --pick services/web.yml --pick services/db.yml \
             --pick overlays/dev.yml --pick base.yml \
  > config.ncl
```

Once `config.ncl` is committed, the env vars become dead weight
— but they don't hurt anything; the dispatcher doesn't read them.

### Stage 2: `config.ncl` is the source of truth

`config.ncl` lists fragments by name. To add or remove a fragment,
edit the list:

```nickel
# config.ncl
[
  import "./base.yml",
  import "./services/web.yml",
  import "./services/db.yml",
  import "./overlays/dev.yml",
]
```

Drop the env vars (or keep them for reference). `nickel export
--format yaml config.ncl > compose.yaml` is now the build step.
The wrapper is no longer used; `NICKEL_COMPOSE` still points at
`config.ncl` so mise/CD-hook invocations work.

If your services reference named volumes and you don't need to
set volume drivers or other options, `base.yml` is also optional
at this stage. The merge engine synthesizes top-level
declarations from service references. See the dummy-project's
`config_no_base.ncl` for the no-root-fragment layout.

### Stage 3: optional — convert fragments to inline records

Convert `services/web.yml` to a Nickel record literal. Inline
comments. Single `config.ncl` becomes the whole deployment.

## Conditional composition

Fragments can declare patches that fire only when a specific
service, volume, or network is (or isn't) selected. Two
conditionals: `if_present` and `if_absent`. Each top-level key
is a gate in the form `"<field>::<value>"` (double colon so
gate values can contain dots). The value is a patch record that
gets merged at the top level when the gate is met.

```nickel
# dev.ncl
{
  if_present = {
    services::redis = {
      services = {
        web = {
          environment = ["REDIS_HOST=redis"],
          depends_on = ["redis"],
        },
      },
    },
  },
}
```

When `redis` is in the merged services, `web` gets `REDIS_HOST`
and depends on redis. If the user skips redis in their
selection, the patch doesn't fire and `web` stays
dependency-free.

`if_absent` is the inverse — the patch fires when the gate is
absent:

```nickel
{
  if_absent = {
    services::postgres = {
      services = {
        db = { image = "postgres:16-alpine" },
      },
    },
  },
}
```

If `postgres` is selected, the local fallback is skipped. If not,
a local `db` service is added.

Resolution order: `if_absent` first, then `if_present`. If both
touch the same field, `if_present` wins (explicit presence
beats default absence). Both fields are stripped from the
rendered output.

The gate field doesn't have to match the patch's first key. A
`volumes::home-data` gate can patch `services.web.environment`
because the engine merges the patch at the top level via
`merge_records` — the patch's structure determines where it
lands.

## What this gives the user

- **Stage 0** is one line: `NICKEL_COMPOSE=./config.ncl` plus
  manually running `dc2nc.sh` once to materialise that file.
- **Stage 1** is mechanical: reorganise your fragment lists
  however you like.
- **Stage 2** is the destination. One `config.ncl` file.
  Typecheck catches typos before any container starts.
- **Stage 3** is optional. Most projects stay at Stage 2.

The end state is "edit `config.ncl`, run `nickel-compose.sh use`,
run `podman-compose up`." No env-var indirection in the
dispatcher, no bash wrapper, no root fragment required.

## What this gives the AI

A future LLM that needs to "run a pod of containers" can write
`config.ncl` directly. The mental model is the bare fragment
list, not a YAML dialect. Same model works for Kubernetes, Helm,
or any other renderer added later — see DESIGN.md.

For migration, the LLM can:
- read existing env vars and project files
- run `dc2nc.sh` to materialise a `config.ncl`
- verify the output is byte-identical to the legacy render
- replace the env vars with the `config.ncl`

That's an abstraction bump: the same deployment description,
expressed at a higher level, validated at write-time, with no
runtime change.
