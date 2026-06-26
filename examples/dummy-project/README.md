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
├── config.ncl               # the Nickel entry point (literal fragment list)
├── wrappers/
│   └── from-compose-file.sh # COMPOSE_FILE-driven variant of the entry point
└── mise/
    └── config.toml          # tools + cd hook + task includes
```

## Two ways to drive the merge

### Option A: literal fragment list (config.ncl)

`config.ncl` lists fragments by name. To add or remove a fragment,
edit the `fragments` array:

```nickel
let fragments = [
  import "./compose.yml",
  import "./services/web.yml",
  import "./services/db.yml",
  import "./overlays/dev.yml",
] in
```

Order matters: later fragments override scalars and concat arrays.
This is the simplest setup — no environment variable required.

### Option B: COMPOSE_FILE-driven (wrappers/from-compose-file.sh)

If you already set `COMPOSE_FILE=frag1.yml:frag2.yml:...` somewhere
(`.env`, `.bashrc`, mise `[env]`, etc.) the wrapper script reads it
and renders `compose.yml`. You keep your existing mental model
— COMPOSE_FILE stays the input list.

```bash
COMPOSE_FILE="compose.yml:services/web.yml:services/db.yml:overlays/dev.yml" \
  ./wrappers/from-compose-file.sh
```

Internally the wrapper generates a temporary `config.ncl` with literal
imports, runs `nickel export`, and cleans up. Why the temp file?
Nickel 1.17 requires `import` paths to be literals at parse time —
runtime paths aren't supported. The wrapper bridges that gap.

When you run `podman-compose up`, podman-compose reads the merged
`compose.yml` (the conventional name) — no `COMPOSE_FILE` env
needed at runtime, since the merged file is the only input.

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
# Option B — COMPOSE_FILE-driven
export COMPOSE_FILE="compose.yml:services/web.yml:services/db.yml:overlays/dev.yml"
./wrappers/from-compose-file.sh
podman-compose config
```

## What gets merged

Both options produce the same `compose.yml`. Render it and look:

- `db` service: image + env from `db.yml`, plus the `5432:5432` port
  from `overlays/dev.yml`. Defaults `networks`/`restart`/`init`
  filled in.
- `web` service: env from `web.yml` + `REDIS_HOST`/`REDIS_PORT`
  from `overlays/dev.yml` (concat). Ports and depends_on from
  `web.yml`.
- `redis` service: added by `overlays/dev.yml` (sibling service).
- Named volumes `web-data`, `db-data`: declared in `compose.yml`.

## The mise cd hook

To keep `compose.yml` fresh without running anything manually,
wire the wrapper into your project's `mise.toml`:

```toml
[hooks]
cd = "QUIET=true $MISE_PROJECT_ROOT/wrappers/from-compose-file.sh"
```

Now every `cd` into the project regenerates `compose.yml` from
your current `COMPOSE_FILE`.

## Migrating your own project

1. Add nickel-compose as a submodule (or vendor it):
   ```bash
   git submodule add https://github.com/keithy/nickel-compose.git nickel-compose
   ```
2. Copy `config.ncl` (Option A) and/or `wrappers/from-compose-file.sh`
   (Option B) into your project.
3. Edit the fragment list or COMPOSE_FILE to match your project.
4. Add the cd hook to your `mise.toml`.
5. `mise trust && mise install`
6. `cd` into the project — `compose.yml` appears.

If you already have `COMPOSE_FILE` set in `.env` or `.bashrc`, you
don't need to touch it. The wrapper reads it as-is.

## Troubleshooting

- **`nickel: command not found` on cd** — run `mise install` once
  on first checkout.
- **`file not found` from nickel export** — typo in `config.ncl`'s
  `fragments` list, or `COMPOSE_FILE` path that doesn't exist. Paths
  in `config.ncl` are relative to the file; paths in `COMPOSE_FILE`
  are relative to cwd.
- **`podman-compose config` rejects output** — usually a malformed
  `${VAR}` in a fragment. Comment out fragments one at a time to find
  the offender.
- **Want to update golden test snapshots** — see top-level
  `tests/merge_spec.sh`; run with `INIT=true mise run test` from the
  repo root.

## Verified

This dummy project is exercised by the bash-spec test suite at the
repo root (`tests/merge_spec.sh`, "end-to-end with dummy-project
example" context). 6 assertions cover service union, env concat,
port merge, named volumes, and podman-compose validation.