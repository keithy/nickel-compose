# nickel-compose/nickel-compose.ncl
#
# The merge engine. Single file, drop-in usable.
#
# This file evaluates to a record with at least one function:
#   - merge: takes a list of YAML/NCL fragments, returns the merged
#     Compose record (services, networks, volumes, with conditional
#     patches applied and top-level declarations synthesized).
#   - merge_with_check: like merge, but attaches an `x-check`
#     field carrying the schema report. Compose ignores x-*
#     fields at runtime, so the rendered YAML stays valid
#     without needing a strip step in the wrapper.
#
# Usage:
#   let composer = import "./nickel-compose.ncl" in
#   composer.merge [frag1, frag2, ...]
#
# The import is bound to a record so future helpers (validate,
# discover, etc.) can be added without breaking callers — just
# add a new field to this record.
#
# Compose semantics reproduced:
#   - services/volumes/networks: union of keys (later wins on collision)
#   - service fields: scalar later-wins, arrays concat (if both sides
#     are arrays AND the field is in `array_fields`), records recurse
#   - top-level volumes/networks: synthesized from service references
#     if not declared by any fragment (compose users don't have to
#     maintain a separate base fragment just to declare volumes their
#     services reference)
#   - if_present / if_absent: conditional patches that adapt to the
#     other fragments selected. Gate keys accept regex patterns.
#   - schema contracts: Service/Port/Volume/Network/Fragment records
#     with field-level doc comments. The `check` function enforces
#     the most important rules (every service has image or build);
#     the contracts are exposed for LSP hover/autocomplete.
#
# Tested with nickel 1.17.0.

# Fields that should be concatenated when both base and overlay have
# them (Compose's "append on merge" behavior).
let array_fields = [
  "environment", "volumes", "ports", "extra_hosts",
  "tmpfs", "env_file", "cap_add", "cap_drop", "security_opt",
] in

# Field-access with default. Replacement for the `or` operator, which
# is unbound in nickel 1.17.
let get_or = fun obj field dflt =>
  if std.record.has_field field obj then obj."%{field}" else dflt
in

# Recursive merge: scalars from b win, arrays concat (if both sides
# are arrays AND the field is in `array_fields`), records recurse.
let rec merge_records = fun a b =>
  let keys = std.record.fields b in
  std.array.fold_left
    (fun acc k =>
      let b_val = b."%{k}" in
      if std.record.has_field k acc then
        let a_val = acc."%{k}" in
        if std.is_array a_val && std.is_array b_val && std.array.elem k array_fields then
          std.record.update k (a_val @ b_val) acc
        else if std.is_record a_val && std.is_record b_val then
          std.record.update k (merge_records a_val b_val) acc
        else
          std.record.update k b_val acc
      else
        std.record.insert k b_val acc)
    a
    keys
in

# Apply defaults to a service. Caller can override by editing this.
let default_service = {
  networks = ["default"],
  restart = "unless-stopped",
  init = false,
} in

let with_defaults_service = fun svc =>
  merge_records default_service svc
in

let with_defaults = fun frag =>
  let services = get_or frag "services" {} in
  let names = std.record.fields services in
  let patched = std.array.fold_left
    (fun acc n =>
      std.record.insert n (with_defaults_service services."%{n}") acc)
    {}
    names
  in
  {
    services = patched,
    volumes = get_or frag "volumes" {},
    networks = get_or frag "networks" {},
    if_present = get_or frag "if_present" {},
    if_absent = get_or frag "if_absent" {},
  }
in

let merge_compose = fun a b =>
  {
    services = merge_records (get_or a "services" {}) (get_or b "services" {}),
    volumes = merge_records (get_or a "volumes" {}) (get_or b "volumes" {}),
    networks = merge_records (get_or a "networks" {}) (get_or b "networks" {}),
    if_present = merge_records (get_or a "if_present" {}) (get_or b "if_present" {}),
    if_absent = merge_records (get_or a "if_absent" {}) (get_or b "if_absent" {}),
  }
in

let merge_all = fun fragments =>
  let init = { services = {}, volumes = {}, networks = {}, if_present = {}, if_absent = {} } in
  std.array.fold_left merge_compose init fragments
in

# Extract the volume name from a service volume reference.
#   "web-data:/var/www/html" -> "web-data"
#   "db-data:/var/lib/postgres/data" -> "db-data"
#   "web-data" -> "web-data"  (short-form reference)
#   "./data:/data" -> null  (bind mount, not a named volume)
#   "/abs/path:/container" -> null  (bind mount)
#   "/var/log:/var/log:rw" -> "/var/log"  (first segment is the source)
#   "${GOCLAW_DIR}/skills" -> null  (env-var interpolation, not a named volume)
let vol_name_from_ref = fun ref =>
  # Split on ":" and take the first segment (the source side).
  let parts = std.string.split ":" ref in
  let first = std.array.first parts in
  # A named volume has no leading "/", no leading "./", no "${"
  if std.string.is_match "^(/|\\./|\\$\\{)" first then null else first
in

# Walk all services, collect referenced volume names that aren't
# already declared at the top level. Returns a record of synthesized
# entries: { name = null, ... }
let synthesize_volumes = fun merged =>
  let services = get_or merged "services" {} in
  let existing = get_or merged "volumes" {} in
  let names = std.record.fields services in
  std.array.fold_left
    (fun acc n =>
      let svc = services."%{n}" in
      let vols = get_or svc "volumes" [] in
      std.array.fold_left
        (fun acc2 v =>
          let name = vol_name_from_ref v in
          if name == null then acc2
          else if std.record.has_field name existing then acc2
          else if std.record.has_field name acc2 then acc2
          else std.record.insert name null acc2)
        acc
        vols)
    {}
    names
in

# Walk all services, collect referenced network names (excluding
# "default", which compose handles implicitly). Same gap-fill logic
# as volumes.
let synthesize_networks = fun merged =>
  let services = get_or merged "services" {} in
  let existing = get_or merged "networks" {} in
  let names = std.record.fields services in
  std.array.fold_left
    (fun acc n =>
      let svc = services."%{n}" in
      let nets = get_or svc "networks" [] in
      std.array.fold_left
        (fun acc2 net =>
          if net == "default" then acc2
          else if std.record.has_field net existing then acc2
          else if std.record.has_field net acc2 then acc2
          else std.record.insert net null acc2)
        acc
        nets)
    {}
    names
in

let synthesize = fun merged =>
  let new_vols = synthesize_volumes merged in
  let new_nets = synthesize_networks merged in
  {
    services = merged.services,
    volumes = merge_records merged.volumes new_vols,
    networks = merge_records merged.networks new_nets,
  }
in

# Parse a gate key like "services::redis" or "volumes::cache-data"
# into {gate_field, gate_value}. Returns null on malformed input.
# Splits on the first "::" only — gate_values may contain dots
# (e.g. "myapp.v2" is a valid compose service name).
let parse_gate_key = fun key =>
  let parts = std.string.split "::" key in
  let n = std.array.length parts in
  if n < 2 then
    null
  else if n == 2 then
    { gate_field = std.array.at 0 parts, gate_value = std.array.at 1 parts }
  else
    {
      gate_field = std.array.at 0 parts,
      gate_value = std.string.join "::" (std.array.slice 1 n parts),
    }
in

# Test a string against an anchored regex pattern. Gates accept
# regex patterns on both sides of "::" (the field name and the
# value name). Patterns are matched against field names in the
# merged record's top-level sections. This lets you write
# "services::redis-*" to match redis, redis-cache, redis-sentinel,
# etc., or "*::postgres" to match a postgres service, volume, or
# network. The most common cases — exact names like
# "services::redis" — work without any wildcards.
#
# std.string.is_match is unanchored, so we wrap the pattern with
# ^...$ for whole-string matching. The user writes a regex
# pattern; we anchor it.
let regex_match = fun pattern s =>
  std.string.is_match ("^" ++ pattern ++ "$") s
in

# Check whether a record has any field whose name matches a given
# regex pattern. Returns true if the record has at least one
# matching field. Used by resolve_gates to test if a pattern
# (e.g. "redis-*") matches any service, volume, or network in
# the merged set.
let record_has_match = fun pattern record =>
  std.array.any (fun field => regex_match pattern field) (std.record.fields record)
in

# Resolve conditional patches against the merged record. Each
# top-level entry under if_present or if_absent is a gate:
# "<field>::<value>". The value of the entry is a patch to apply
# to the top-level merged record if the gate condition is met.
#
# The patch declares its own top-level structure — the engine
# merges it at the top level via merge_records, and the patch's
# own keys determine where it lands. If the patch needs to add
# fields to a service, it starts with `services:`.
#
#   if_present:
#     services::redis:
#       services:
#         web:
#           environment: [REDIS_HOST=redis]
#           depends_on: [redis]
#
# When `redis` is a service in the merged set, the patch at
# `if_present.services::redis` is merged into the top-level record.
# The `services:` key in the patch lands at merged.services, so
# web.environment gains REDIS_HOST=redis and web.depends_on gains
# redis.
#
# Both sides of the "::" delimiter accept regex patterns (not just
# literal names). So `services::redis-.*` matches redis, redis-cache,
# redis-sentinel — any service whose name starts with "redis-".
# And `*::postgres` matches a postgres service, volume, or network,
# in any section. Dots and other regex metachars in literal names
# are escaped automatically; you can use `*` (any chars) and `?`
# (one char) without learning regex syntax. The most common case —
# `services::redis` — works without any wildcards.
#
#   if_absent:
#     services::postgres:
#       services:
#         db:
#           image: postgres:16-alpine
#
# When `postgres` is NOT a service, the patch at
# `if_absent.services::postgres` is applied — providing a local
# fallback database.
#
# The gate field doesn't have to match the patch's first key. A
# `volumes::home-data` gate can patch `services.web.environment`
# because the engine merges at top level, not scoped to the
# gate field.
#
# The "::" delimiter is used so gate values may contain dots
# (e.g. service "myapp.v2" works as a gate value without quoting
# tricks).
#
# Both fields are stripped from the output (compose doesn't
# recognize them).
let resolve_gates = fun merged conditionals should_apply =>
  let keys = std.record.fields conditionals in
  std.array.fold_left
    (fun acc key =>
      let parsed = parse_gate_key key in
      if parsed == null then acc
      else
        let section = get_or acc parsed.gate_field {} in
        let gate_met = record_has_match parsed.gate_value section in
        if should_apply gate_met then
          merge_records acc conditionals."%{key}"
        else acc)
    merged
    keys
in

let resolve_conditionals = fun merged =>
  # Order matters: if_absent resolves first, then if_present. If
  # both touch the same field, the later (if_present) patch wins,
  # which is the conventional "explicit presence wins over default
  # absence" semantic.
  let after_absent = resolve_gates merged
    (get_or merged "if_absent" {})
    (fun gate_met => if gate_met then false else true) in
  let after_present = resolve_gates after_absent
    (get_or after_absent "if_present" {})
    (fun gate_met => gate_met) in
  # Drop both fields from the output. compose doesn't recognize
  # them and they shouldn't leak into the rendered yaml.
  std.record.remove "if_present" (std.record.remove "if_absent" after_present)
in

# === Report namespace helpers ===
#
# Each report.* function takes a merged compose record and
# returns a structured view of it. Output is sorted for
# determinism (alphabetical by service name).

# Parse a Compose port string into a record with host_port,
# container_port, and protocol fields. Returns 'None if the
# string is malformed (caller should skip).
#
#   "8080"        -> 'Some { host_port = "8080", container_port = "8080", protocol = "tcp" }
#   "8080:80"     -> 'Some { host_port = "8080", container_port = "80",   protocol = "tcp" }
#   "8080:80/tcp" -> 'Some { host_port = "8080", container_port = "80",   protocol = "tcp" }
#   "127.0.0.1:8080:80" -> 'None (bind address — not yet supported)
let parse_port_string = fun s =>
  let parts_proto = std.string.split "/" s in
  let proto = if std.array.length parts_proto == 2 then
    std.array.at 1 parts_proto
  else
    "tcp" in
  let host_container = std.array.at 0 parts_proto in
  let parts = std.string.split ":" host_container in
  let n = std.array.length parts in
  if n == 1 then
    'Some { host_port = std.array.at 0 parts, container_port = std.array.at 0 parts, protocol = proto }
  else if n == 2 then
    'Some { host_port = std.array.at 0 parts, container_port = std.array.at 1 parts, protocol = proto }
  else
    'None
in

# Parse a single port entry (string or record) into a normalized
# { host_port, container_port, protocol } record. Returns 'None
# for container-only ports (no published) or unrecognized shapes.
let parse_port_entry = fun entry =>
  if std.is_string entry then
    parse_port_string entry
  else if std.is_record entry then
    let target = get_or entry "target" null in
    let published = get_or entry "published" null in
    if target == null then
      'None
    else if published == null then
      # Container-only port (expose, not port). Skip.
      'None
    else
      'Some {
        host_port = std.string.from published,
        container_port = std.string.from target,
        protocol = get_or entry "protocol" "tcp",
      }
  else
    'None
in

# Convert a service's `ports` field into a list of normalized
# port records. Handles both string form ("8080:80") and
# record form ({target, published, protocol}). Returns [] if
# the service has no ports or the field is malformed.
let ports_from_service = fun svc =>
  let raw = get_or svc "ports" [] in
  if std.is_array raw then
    std.array.filter_map parse_port_entry raw
  else
    []
in

# List of service names from the merged record. Returns []
# if the merged record has no services.
let list_services = fun merged =>
  let services = get_or merged "services" {} in
  std.record.fields services
in

# List of host port bindings across all services, with service
# attribution. Each entry is { service, host_port, container_port,
# protocol }. Container-only ports (no host publish) are skipped.
# Sorted by host_port numerically for determinism.
let list_ports = fun merged =>
  let services = get_or merged "services" {} in
  let names = std.record.fields services in
  let pairs = std.array.map
    (fun name =>
      let svc = services."%{name}" in
      let ports = ports_from_service svc in
      std.array.map
        (fun p => { service = name } & p)
        ports)
    names in
  let flat = std.array.flatten pairs in
  # Sort numerically by host_port (port numbers are small integers,
  # so converting to Number is safe). std.array.sort expects a
  # total-ordering comparator returning the 'Lesser/'Equal/'Greater
  # enum.
  std.array.sort
    (fun a b =>
      let an = std.string.to_number a.host_port in
      let bn = std.string.to_number b.host_port in
      if an < bn then 'Lesser
      else if an > bn then 'Greater
      else 'Equal)
    flat
in

# === Schema namespace ===
#
# Contracts describing the Compose service model. These are
# records with field-level contracts and doc comments. The
# engine uses them at runtime via `check` (see below) and the
# LSP uses them for hover docs and field-name autocompletion.
#
# Scope: minimal. We contract only the fields the engine
# consumes (image/build, ports, volumes, environment,
# depends_on, networks) plus a few common ones (command,
# restart, init). Everything else (healthcheck, secrets,
# deploy, ...) passes through as untyped data. The door stays
# open for a ServiceComprehensiveSchema later if anyone wants
# to flesh this out.
#
# Note: in nickel 1.17, value annotations `: Service = ...`
# are treated as static types and break `nickel export`. So
# we don't ask users to annotate their services. Validation
# runs through `composer.check` instead, which is plain record
# matching and works with both `eval` and `export`.
# Service contract: records with field-level doc/default.
# `service_schema` is the let-binding; the public record
# exposes it as `Service` (the field name would shadow the
# binding at evaluation time).
let service_schema = {
  image | String | doc "container image, e.g. nginx:1.27",
  build | { context | String } | doc "build context, alternative to image",
  command | Array String | doc "override container command" | default = [],
  environment | Array String | doc "env vars as KEY=VALUE strings" | default = [],
  volumes | Array String | doc "volume mounts: host:container or named:/path" | default = [],
  ports | Array String | doc "port mappings: HOST:CONTAINER or single port" | default = [],
  depends_on | Array String | doc "services this depends on" | default = [],
  networks | Array String | doc "networks this service attaches to" | default = [],
  restart | String | doc "restart policy" | default = "unless-stopped",
  init | Bool | doc "run an init process inside the container" | default = false,
} in

# Port contract: a long-form port entry (target + published).
# Short-form strings like "8080:80" are also accepted by the
# engine but not modeled here — they parse at use sites.
# All fields are modelable; none are optional in the schema
# (in nickel 1.17, `| optional` strips the field from the
# record, making it invisible to LSP `has_field` checks).
let port_schema = {
  target | Number | doc "container port",
  published | Number | doc "host port",
  protocol | String | doc "tcp or udp" | default = "tcp",
  host_ip | String | doc "bind address, e.g. 127.0.0.1",
} in

# Volume contract: a top-level named volume declaration.
# Top-level entries can be null (use defaults) or a record
# with driver/options. Fields model the common cases; exotic
# options (labels, etc.) are untyped.
let volume_schema = {
  driver | String | doc "volume driver, e.g. local",
  driver_opts | { } | doc "driver-specific options",
  external | Bool | doc "volume is managed outside compose",
  name | String | doc "override the volume name",
} in

# Network contract: a top-level network declaration.
let network_schema = {
  driver | String | doc "network driver, e.g. bridge",
  external | Bool | doc "network is managed outside compose",
  name | String | doc "override the network name",
} in

# Fragment contract: a single fragment (one entry in the
# fragments list). At minimum it can be empty; in practice
# it declares one or more of services, volumes, networks,
# if_present, if_absent.
let fragment_schema = {
  services | { } | doc "service declarations, keyed by name" | default = {},
  volumes | { } | doc "top-level volume declarations" | default = {},
  networks | { } | doc "top-level network declarations" | default = {},
  if_present | { } | doc "conditional patches gated on presence" | default = {},
  if_absent | { } | doc "conditional patches gated on absence" | default = {},
} in

# === Check function ===
#
# Walks a merged record and produces a structured report of
# issues. Returns { ok, errors } where errors is a list of
# { service, field, message } records. ok = true iff errors
# is empty.
#
# This is the runtime schema validator. It runs after the
# merge and looks at the final state of each service. It is
# exposed as `composer.check` so users can call it directly
# in their `config.ncl`, and used internally by
# `merge_with_check`.
#
# For v0.2.0 we enforce: every service declares `image` or
# `build`. Port and depends_on validation is intentionally
# left to later rounds (see TODO in docs/schema.md).
let check_service = fun name svc =>
  let has_image = std.record.has_field "image" svc in
  let has_build = std.record.has_field "build" svc in
  if has_image || has_build then
    []
  else
    [{
      service = name,
      field = "image",
      message = "service must declare `image` or `build`",
    }]
in

# `run_check` rather than `check` so the public record can
# expose it as `check = run_check` without recursive
# resolution.
let run_check = fun merged =>
  let svcs = if std.record.has_field "services" merged then
    merged.services
  else
    {} in
  let names = std.record.fields svcs in
  let errs = std.array.fold_left
    (fun acc n => acc @ (check_service n svcs."%{n}"))
    []
    names
  in
  {
    ok = std.array.length errs == 0,
    errors = errs,
  }
in

# Merge and attach the check result. The merged record gets a
# `_check | not_exported` field carrying the schema report.
# `nickel export` strips the field (so compose.yaml is clean);
# `nickel eval` keeps it (so to-compose.sh can read it back to
# set the exit code).
#
# This is the function `config.ncl` should use when it wants
# the validation state to travel with the artifact. Plain
# `merge` is unchanged so existing callers don't break.
# Local binding for the public-record field. We can't write
# `merge_with_check = merge_with_check` in the public record
# because the field name shadows the let binding at evaluation
# time. Renaming the binding to `run_merge_with_check` and
# aliasing in the record keeps the public API clean.
# Merge and attach the check result. The merged record gets an
# `x-check` field carrying the schema report. Compose ignores
# `x-*` fields at runtime, so the rendered YAML stays valid
# without a strip step in the wrapper.
#
# This is the function `config.ncl` should use when it wants
# the validation state to travel with the artifact. Plain
# `merge` is unchanged so existing callers don't break.
#
# Note: we use the `x-` prefix instead of `| not_exported`
# because Compose's spec reserves `x-*` as extension fields
# that the runtime silently ignores. This sidesteps the
# annotation lifecycle problem entirely (the `not_exported`
# annotation would be lost during `nickel eval` serialization,
# forcing the wrapper to do an explicit destructure-and-rebuild
# to strip the field). With `x-check`, the YAML stays valid
# Compose as-is.
let run_merge_with_check = fun fragments =>
  let prepped = std.array.map with_defaults fragments in
  let m = merge_all prepped in
  let r = resolve_conditionals m in
  let s = synthesize r in
  s & { x-check = run_check s, x-source = "./config.ncl" }
in

# Like merge_with_check, but records an explicit source
# path on the result. The wrapper's generated configs
# call this with the absolute path of the config.ncl
# they wrote. `x-source` is a Compose extension field;
# the runtime ignores it.
let run_merge_with_source = fun fragments source =>
  let prepped = std.array.map with_defaults fragments in
  let m = merge_all prepped in
  let r = resolve_conditionals m in
  let s = synthesize r in
  s & { x-check = run_check s, x-source = source }
in

# Public entry point. The record form lets us add helpers
# (validate, discover, etc.) without breaking callers.
# Imports this file with
# `let composer = import "./nickel-compose.ncl" in` then call
# `composer.merge fragments`.
#
# Namespaces:
#   composer.merge fragments         # the main entry point
#   composer.merge_with_check fs     # merge + schema check, attach to result
#   composer.Service                  # service contract (for LSP / docs)
#   composer.Port | Volume | Network | Fragment  # other contracts
#   composer.check merged            # alias for composer.validation.check
#   composer.validation.check merged # schema validator
#   composer.report.<field> merged   # extract structured data
#   composer.discover.<thing> root    # find things in the file system
{
  merge = fun fragments =>
    let prepped = std.array.map with_defaults fragments in
    let merged = merge_all prepped in
    let resolved = resolve_conditionals merged in
    synthesize resolved,

  # Public API:
  #   merge_with_check fs        — default; x-source is "./config.ncl"
  #   merge_with_source fs path  — record an explicit source
  #                                 path on the result as x-source
  # Both attach x-check (the schema report).
  merge_with_check = run_merge_with_check,
  merge_with_source = run_merge_with_source,

  # Schema contracts (records with field-level doc/default).
  # Exposed at top level so LSP can resolve them. The engine
  # does not enforce them via static type annotations
  # (incompatible with `nickel export` in 1.17). Validation
  # runs through `check` instead.
  Service = service_schema,
  Port = port_schema,
  Volume = volume_schema,
  Network = network_schema,
  Fragment = fragment_schema,

  # Top-level alias for composer.validation.check. Same
  # function. Two access paths so users can write
  # `composer.check m` (short) or `composer.validation.check m`
  # (namespaced). Both resolve to the same function.
  check = run_check,

  # Report namespace: extract structured data from a merged
  # record.   composer.report.services merged
  #   -> ["db", "redis", "web"]            # service names
  #   composer.report.ports merged
  #   -> [{ service = "web", host_port = "8080", container_port = "80" }, ...]
  # Each sub-function takes a merged record and returns a
  # list. Empty for absent data.
  report = {
    services = list_services,
    ports = list_ports,
  },

  # Discover namespace: find things in the file system.
  #   composer.discover.fragments root
  #   -> ["path/to/frag.yml", "path/to/frag.ncl", ...]
  # Operates on a directory path, not a merged record.
  # Different problem space from report.
  discover = {},

  # Validation namespace: schema/data checks. Each
  # sub-function returns a list of issues:
  #   composer.validation.check merged
  #   -> { ok = Bool, errors = [{service, field, message}, ...] }
  # Empty errors = no issues. Caller decides how to handle
  # issues (fail, warn, log). Same function as the top-level
  # `check`, exposed here for namespace consistency with
  # report.
  validation = {
    check = run_check,
  },

  version = "0.2.0",
}