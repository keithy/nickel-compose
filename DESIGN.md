# DESIGN — The Abstraction Bump

## What we're after

Compose today is a bag of YAML quirks that every team reinvents
badly. Nickel-compose is the move from that bag to a typed,
ordered, composable description of a deployment. The system does
the same thing before and after; humans reason about it
differently.

## The pain we're moving past

| Compose pain | Why it hurts |
|---|---|
| No fragment picker | Every team writes `compose-services-select.sh` (or equivalent) and gets it slightly wrong. Bash + grep + sed is not the right tool for declaring which fragments combine into a stack. |
| `COMPOSE_FILE=a:b:c` | Clumsy. One line. No inline expansion of other env vars. Tied to the colon-separated idiom for historical reasons. |
| No typecheck | A typo in a service name, a wrong env var name, a missing required field — all pass compose validation and fail at `podman compose up`. Container start is the worst place to discover a typo. |
| Not composable | Overlays merge via `!reset`, anchor merge (`*alias`, `&alias`), `${VAR:?msg}`. Each is a YAML loader quirk or a Compose extension. Knowledge of these is tribal, not in the type system. |
| Needs `base.yml` | The output filename `compose.yml` collides with the conventional root fragment name. Workaround: rename the root. Workaround-of-the-workaround: write a tiny file that just declares `networks` and `volumes`. |
| Order matters silently | Wrong order = silently wrong overlay. No warning, no validation. Compose's "later wins" is a rule humans have to remember, not a property of the description. |

## What nickel-compose fixes

| Pain | Solution |
|---|---|
| No picker | `config.ncl` *is* the picker. Declarative list of fragments. |
| `COMPOSE_FILE` | `COMPOSE_FRAGMENTS` for the input list (clearly named for its role). `${VAR}` interpolation works the same way compose does — Nickel passes the strings through verbatim. |
| No typecheck | Contracts. Missing field → typecheck error with file:line, before any container starts. Per-fragment contracts as needed (`GoclawBase`, `PostgresBase`, etc.). |
| Not composable | One merge engine in `lib/merge.ncl`. `array_fields` list controls concat-vs-replace. Records recurse. Records union at the top level. All explicit, all in one file, all readable. |
| Needs `base.yml` | The merge engine auto-fills defaults (`networks`, `restart`, `init`) per service. A root fragment is needed only for top-level `volumes:` declarations — and even that can be folded into a fragment named anything other than the auto-pick output. |
| Order matters silently | Order still matters for `b wins on collision` semantics — that's intrinsic to overlay composition. But the typecheck catches missing required keys regardless of order, and the merge engine's behavior is the same in both directions of any two-fragment merge. |

## The two-way bet

Nickel-compose supports two authoring modes, both first-class:

### Decompose: many fragments → one merged `compose.yml`

For projects that want git-diff-friendly per-service files:

```
services/
├── web.yml
├── db.yml
└── redis.yml
overlays/
└── dev.yml
base.yml
config.ncl    # imports the above
```

`config.ncl` lists the fragments, the merge engine combines them,
`compose.yml` is the output. Each YAML is small, reviewable,
focused.

### Monolith: one big `config.ncl` → one `compose.yml`

For projects (or LLMs) that want one file with all the comments
in a sensible order:

```nickel
# config.ncl — single-file deployment description.

let build = import "nickel-compose/lib/merge.ncl" in

let fragments = [
  # === Root: networks and named volumes ===
  {
    networks = { default = { driver = "bridge" } },
    volumes = { "web-data" = null, "db-data" = null },
  },

  # === Services ===
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

  # === Local dev overlay ===
  {
    services = {
      db = { ports = ["5432:5432"] },
      redis = { image = "redis:7-alpine" },
    },
  },
] in

build fragments
```

Same merge engine, same output. Comments live where humans read
them. An LLM generating this file describes a deployment
declaratively with no bash-picker mental model required.

## The AI angle

A future LLM that needs to "run a pod of containers" should think
at the nickel-compose level, not the compose level. The mental
model:

> A typed record describing services, networks, volumes.
> Defaults filled in. Fragment order doesn't matter for
> correctness. Validation at write-time, not run-time. One
> source-of-truth file or many — same output.

Compared to compose:

> A YAML file with `${VAR:?}` and `!reset` and a bash picker
> you have to understand before you can read it.

The LLM that writes `config.ncl` produces something:
- a human can read
- a typechecker validates before any container starts
- that doesn't have order-dependent surprises
- that's either one file or many, by author choice

The LLM that writes compose YAML produces something:
- that's "valid YAML" but maybe not valid compose
- where `!reset` and anchor merge and `${VAR:?}` are tribal
  knowledge the LLM may or may not have
- that runs through a bash picker to be assembled
- where order matters and is invisible

## Robustness properties we want

1. **`config.ncl` is the canonical source.** Even when there are
   many fragment files behind it. Delete all the YAMLs and rebuild
   from `config.ncl` alone (with fragments inlined as literals).

2. **Merge semantics live in `contracts.ncl`, not in the user's
   head.** A user should be able to say "fragment B has
   `volumes: [...]`, fragment A also has `volumes: [...]`, they
   concat" without knowing whether that's `&`, `+`, or "depends
   on Compose version." It's `array_fields` in one place.

3. **Order-independence for correctness** (not for last-wins on
   scalars, which is fundamental). If two fragments don't
   conflict, order shouldn't matter. If they do conflict, the
   typecheck should warn.

4. **Typecheck is the safety net.** Missing fields, wrong types,
   undefined references. Compose has none of this; nickel-compose
   gets it from Nickel's contract system.

5. **One big file or many, both first-class.** Monolith with
   comments for humans. Many fragments for git-diff hygiene. Same
   engine, same output.

## What this is NOT

- Not a wrapper around `podman compose`. The output is plain
  Compose YAML; the runtime tool is unchanged.
- Not a new compose dialect. We emit valid compose YAML, nothing
  custom.
- Not a runtime dependency. Nickel runs at build time only.
- Not a replacement for compose. It's an authoring layer above
  it.

## Status

The merge engine (`lib/merge.ncl`), the typecheck scaffolding,
and the wrapper are working. The example (dummy-project) shows
both authoring modes (literal list in `config.ncl`,
`COMPOSE_FRAGMENTS`-driven wrapper). The dual-direction bet is
proven.

What's not yet there:
- Per-fragment contracts (GoclawBase, PostgresBase, etc.) for
  catching real bugs at typecheck time.
- Auto-emit of an empty root fragment when the list has none.
- A `nickel compose fragments <config.ncl>` command to decompose
  a monolith into per-service files.
- A `nickel compose merge <fragment.ncl> ...` command to compose
  fragments from CLI.
- Integration with the wider podclaws project (currently a
  submodule).

These are the next abstraction bumps.

## The bigger bet: a deployment model, not just a compose tool

If nickel-compose can describe a deployment as a typed record
and emit valid `compose.yml`, the same record can emit valid
Kubernetes manifests. Helm charts. Nomad jobs. Anything that
takes a declarative description of "what should run" and turns
it into a runtime config.

The premise is the one podman-compose was built on: the same
mental model ("a pod of containers with volumes and a network")
describes both Compose and Kubernetes. What changes is the
output format. What stays is the structure: services,
volumes, networks, dependencies, env vars, ports.

Concretely, once the merge engine produces a clean `Compose`
record:

- `nickel compose render config.ncl` → `compose.yml`
- `nickel k8s render config.ncl` → Deployment + Service + PVC
  manifests
- `nickel helm render config.ncl` → `Chart.yaml` + `values.yaml`
  + `templates/*.yaml`

Each renderer is a Nickel function that walks the same `Compose`
record. The user's mental model is unchanged. The runtime
target changes.

This is the durable abstraction: not "a better compose tool"
but "the level above compose, where compose is one of several
output targets." Today the only renderer is Compose. The shape
of the input is what makes future renderers cheap to add.

If we get this right, the AI angle widens: an LLM that learns
to write `config.ncl` can target any container orchestrator by
swapping the renderer. The deployment description is portable;
the output format is the runtime's concern.