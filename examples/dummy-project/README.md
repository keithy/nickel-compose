# dummy-project — first-time user example

A self-contained example showing how to add nickel-compose to an
existing podman/docker-compose project. No external dependencies —
everything you need is in this directory.

## What's here

```
dummy-project/
├── compose.yml              # root: networks + named volumes
├── services/
│   ├── web.yml              # web service skeleton
│   └── db.yml               # database service skeleton
├── overlays/
│   └── dev.yml              # local development overlay (adds redis, exposes db)
├── config.ncl               # the Nickel entry point
└── mise/
    └── config.toml          # tools + cd hook + task includes
```

## Try it

```bash
cd examples/dummy-project
mise trust
mise install
mise run render             # produces podman-compose.yml
podman-compose config       # validates
```

## What this demonstrates

1. **A project that didn't use Nickel before.** YAML fragments in
   `compose.yml`, `services/`, `overlays/` — the conventional layout.

2. **One `config.ncl` to rule them all.** Replaces whatever picker
   script you were using (`.env-compose` + `COMPOSE_FILE` + bash).
   Lists fragments in declaration order; comment lines to disable.

3. **The mise cd hook.** Every time you `cd` into the project,
   `podman-compose.yml` is regenerated from `config.ncl`. No
   "remember to re-render" step.

4. **Defaults filled in automatically.** Each service gets
   `networks: [default]`, `restart: unless-stopped`, `init: false`
   unless the fragment already specifies them. The merged YAML
   has them, but the source fragments stay small.

## What gets merged

Render `podman-compose.yml` and look:

- `db` service: image + env from `db.yml`, plus the `5432:5432` port
  from `overlays/dev.yml`. Defaults `networks`/`restart`/`init`
  filled in.
- `web` service: env from `web.yml` + `REDIS_HOST`/`REDIS_PORT`
  from `overlays/dev.yml` (concat). Ports and depends_on from
  `web.yml`.
- `redis` service: added by `overlays/dev.yml` (sibling service).
- Named volumes `web-data`, `db-data`: declared in `compose.yml`.

## Migrating your own project

1. `git submodule add https://github.com/keithy/nickel-compose.git nickel-compose`
2. Copy `config.ncl` from this directory to your project root.
3. Edit the `fragments` list to match your project's YAML files.
4. Copy `mise/config.toml` (or merge into your existing one) — adjust
   the `[task_config] includes` path to point at `nickel-compose/mise/tasks`.
5. `mise trust && mise install`
6. `mise run render`
7. Delete your old picker script and `.env-compose`.

For an existing project that already uses `COMPOSE_FILE=frag1:frag2:...`,
the equivalent config.ncl can read that env var instead of listing
fragments manually — see the "Reading COMPOSE_FILE from the environment"
comment in `config.ncl`.