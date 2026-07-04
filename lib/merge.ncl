# nickel-compose/lib/merge.ncl
#
# Generic merge engine for podman/docker compose fragments.
#
# This file evaluates to a single function `build` that takes a list
# of YAML fragments and returns a merged Compose record.
#
# Usage:
#   let build = import "./lib/merge.ncl" in
#   build [frag1, frag2, ...]
#
# Compose semantics reproduced:
#   - services/volumes/networks: union of keys (later wins on collision)
#   - service fields: scalar later-wins, arrays concat (if both sides
#     are arrays AND the field is in `array_fields`), records recurse
#   - top-level volumes/networks: synthesized from service references
#     if not declared by any fragment (compose users don't have to
#     maintain a separate base fragment just to declare volumes their
#     services reference)
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
  }
in

let merge_compose = fun a b =>
  {
    services = merge_records (get_or a "services" {}) (get_or b "services" {}),
    volumes = merge_records (get_or a "volumes" {}) (get_or b "volumes" {}),
    networks = merge_records (get_or a "networks" {}) (get_or b "networks" {}),
  }
in

let merge_all = fun fragments =>
  let init = { services = {}, volumes = {}, networks = {} } in
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

# Public entry point: takes a list of fragments, returns merged Compose.
# Imports this file with `let build = import "./lib/merge.ncl" in`
# then call `build fragments`.
fun fragments =>
  let prepped = std.array.map with_defaults fragments in
  let merged = merge_all prepped in
  synthesize merged