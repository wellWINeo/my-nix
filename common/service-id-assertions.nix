{ config, lib, ... }:

let
  inherit (lib) filter mapAttrsToList concatStringsSep;

  collectDupes =
    entries: idField:
    let
      withId = filter (e: e.${idField} != null) entries;
      grouped = lib.groupBy (e: toString e.${idField}) withId;
      dupeGroups = lib.filterAttrs (_: g: builtins.length g > 1) grouped;
    in
    mapAttrsToList (id: g: {
      inherit id;
      names = map (e: e.name) g;
    }) dupeGroups;

  userEntries = mapAttrsToList (n: u: {
    name = n;
    uid = u.uid;
  }) config.users.users;

  groupEntries = mapAttrsToList (n: g: {
    name = n;
    gid = g.gid;
  }) config.users.groups;

  uidDupes = collectDupes userEntries "uid";
  gidDupes = collectDupes groupEntries "gid";

  mkAssertion = field: d: {
    assertion = false;
    message = "Duplicate ${field} ${d.id} assigned to: ${concatStringsSep ", " d.names}";
  };
in
{
  assertions = (map (mkAssertion "UID") uidDupes) ++ (map (mkAssertion "GID") gidDupes);
}
