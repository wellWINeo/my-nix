{ ... }:

let
  collectModules =
    dir:
    builtins.concatMap (
      name:
      let
        path = dir + "/${name}";
        type = builtins.readFileType path;
      in
      if type == "directory" then
        if builtins.pathExists (path + "/default.nix") then [ path ] else collectModules path
      else if type == "regular" && name != "default.nix" && builtins.match ".*\\.nix$" name != null then
        [ path ]
      else
        [ ]
    ) (builtins.attrNames (builtins.readDir dir));
in
{
  imports = collectModules ./. ++ [ ../common/service-id-assertions.nix ];
}
