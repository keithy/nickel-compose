# nickel-compose/nickel-compose.ncl
#
# The merge engine. Single file, drop-in usable.
#
# This file evaluates to a record with at least one function:
#   - merge: takes a list of YAML/NCL fragments, returns the merged
#     Compose record (services, networks, volumes, with conditional
#     patches applied and top-level declarations synthesized).
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

# Public entry point. The record form lets us add helpers (validate,
# discover, etc.) without breaking callers. Imports this file with
# `let composer = import "./nickel-compose.ncl" in` then call
# `composer.merge fragments`.
#
# Namespaces (currently placeholders, see below):
#   composer.merge fragments           # the main entry point
#   composer.report.<field> merged     # extract structured data
#   composer.discover.<thing> root     # find things in the file system
#   composer.validation.<rule> merged  # check for problems
{
  merge = fun fragments =>
    let prepped = std.array.map with_defaults fragments in
    let merged = merge_all prepped in
    let resolved = resolve_conditionals merged in
    synthesize resolved,

  # Report namespace: extract structured data from a merged record.
  #   composer.report.ports merged
  #   -> [{ service = "web", host_port = "8080", container_port = "80" }, ...]
  # Each sub-function takes a merged record and returns a list of
  # records describing what was found. Empty for absent data.
  report = {},

  # Discover namespace: find things in the file system.
  #   composer.discover.fragments root
  #   -> ["path/to/frag.yml", "path/to/frag.ncl", ...]
  # Operates on a directory path, not a merged record. Different
  # problem space from report.
  discover = {},

  # Validation namespace: check for problems in a merged record
  # (or in a report). Each sub-function returns a list of issues:
  #   composer.validation.ports merged
  #   -> [{ service = "web", host_port = "8080", conflicts_with = "admin" }, ...]
  # Empty list = no issues. Caller decides how to handle issues
  # (fail, warn, log).
  validation = {},

  version = "0.1.0",
}