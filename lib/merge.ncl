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

# Public entry point: takes a list of fragments, returns merged Compose.
# Imports this file with `let build = import "./lib/merge.ncl" in`
# then call `build fragments`.
fun fragments =>
  let prepped = std.array.map with_defaults fragments in
  merge_all prepped