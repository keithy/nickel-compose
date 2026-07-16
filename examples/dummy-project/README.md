# dummy-project — first-time user example

A self-contained example showing how to add nickel-compose to an
existing podman/docker-compose project. Compose fragments live here;
the dispatcher at the nickel-compose repo root (`../../bin/nickel-compose`)
drives the merge.

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
├── config.ncl               # all-YAML entry point — bare fragment list
├── config_ncl.ncl           # all-Nickel entry point — with schema check
├── config_with_check.ncl    # explicit composer.check call
├── config_mixed.ncl         # partial migration demo
├── config_no_base.ncl       # no root fragment — engine synthesizes from services
└── mise/
    └── config.toml          # tools + cd hook + task includes
```

The dispatcher `nickel-compose` and the fragment picker `dc2nc.sh`
live at the nickel-compose repo root (`../../`).

The root fragment is named `base.yml`, not `compose.yaml`, because
`compose.yaml` is reserved as the merged output filename (auto-picked
by podman-compose and docker compose). Naming the source `base.yml`
avoids any collision.

**You don't actually need a base fragment.** The merge engine scans
service volume and network references and synthesizes top-level
declarations. See `config_no_base.ncl` for the demo.

## How it works

```
fragments/*.yml  --[dc2nc.sh]-->  config.ncl  --[use]-->  compose.yaml  --[podman compose]-->  containers
                                              |
                                              +-- imports YML/NCL fragments
                                              +-- applies defaults per service
                                              +-- merges fragments with Compose semantics
```

1. **Pick your fragments** with `dc2nc.sh` (or write `config.ncl` by hand).
2. **Render** with `nickel-compose use [config.ncl]` — defaults to
   `$NICKEL_COMPOSE` if set, else `./config.ncl`.
3. **Deploy** with `podman compose up` — it auto-picks `compose.yaml`.

## Try it

```bash
cd examples/dummy-project
mise trust
mise install
```

Then either render directly:

```bash
mise run render             # uses ./config.ncl
podman-compose config       # validates
```

or generate a config from your fragments:

```bash
# Pipe a curated list through dc2nc.sh and save as config.ncl
find . \( -name '*.yml' -o -name '*.ncl' \) \
  | ../../scripts/dc2nc.sh --pick base.yml \
                           --pick services/web.yml \
                           --pick services/db.yml \
                           --pick overlays/dev.yml \
  > config.ncl

# Then render and validate
../../bin/nickel-compose use
podman-compose config
```

## Generating config.ncl with dc2nc.sh

`dc2nc.sh` reads a list of fragment paths on stdin and writes a
bare-list `config.ncl` on stdout. All candidates appear as commented
examples; the picked subset is uncommented and live:

```nickel
# dc2nc.sh output — bare-list config.ncl
# Uncomment a line to enable a fragment. The picked subset is live.
[
  import "./base.yml",
  import "./services/web.yml",
  # import "./services/db.yml",
  # import "./overlays/dev.yml",
  ...
]
```

So the workflow is: pipe fragments in, pick what you want, save
the result as `config.ncl`. Edit the file by hand to add or
remove fragments later — it's just a plain list.

```bash
# Discover + pick in one step
dc2nc.sh --find-all --pick base.yml --pick services/web.yml > config.ncl
```

Same basename in different directories is fine: `dc2nc.sh` matches
by relative path, so `agent/base.yml` and `database/base.yml` are
unambiguously distinct.

## NICKEL_COMPOSE: the default config path

`NICKEL_COMPOSE` is a single env var pointing at a `config.ncl`.
If your mise/direnv/CD-hook sets it, bare `nickel-compose use`
renders that config without any args:

```bash
# mise.toml
[env]
NICKEL_COMPOSE = "./config.ncl"

[hooks]
postcd = "nickel-compose use"
```

An explicit `use config.ncl` always wins over `$NICKEL_COMPOSE`,
so the env var is purely a default.

## What gets merged

The render produces `compose.yaml`. Look at it:

- `db` service: image + env from `db.yml`, plus the `5432:5432` port
  from `overlays/dev.yml`. Defaults `networks`/`restart`/`init`
  filled in.
- `web` service: env from `web.yml` + `REDIS_HOST`/`REDIS_PORT`
  from `overlays/dev.yml` (concat). Ports and depends_on from
  `web.yml`.
- `redis` service: added by `overlays/dev.yml` (sibling service).
- Named volumes `web-data`, `db-data`: declared in `compose.yaml`.

## Migrating your own project

1. Add nickel-compose as a submodule (or vendor it):
   ```bash
   git submodule add https://github.com/keithy/nickel-compose.git nickel-compose
   ```
2. Generate a `config.ncl` with `dc2nc.sh` (see above), or write
   one by hand. Point `NICKEL_COMPOSE` at it via mise `[env]` or
   `.envrc`.
3. Add the postcd hook to your `mise.toml`:
   ```toml
   [hooks]
   postcd = "nickel-compose/bin/nickel-compose use"
   ```
4. `mise trust && mise install`
5. `cd` into the project — `compose.yaml` appears.

`podman compose up` reads the merged `compose.yaml` directly — no
runtime env var needed.
