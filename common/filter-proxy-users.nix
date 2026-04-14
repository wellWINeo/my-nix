# common/filter-proxy-users.nix
#
# Filters singBoxUsers by the `hosts` property for a given hostname.
#   hosts = "*"           → allowed everywhere (also the default when absent)
#   hosts = "veles"       → only on veles
#   hosts = ["veles", "buyan"] → only on veles and buyan
{ lib }:
hostname: users:
builtins.filter (
  u:
  let
    h = u.hosts or "*";
  in
  if h == "*" then
    true
  else if builtins.isList h then
    builtins.elem hostname h
  else
    h == hostname
) users
