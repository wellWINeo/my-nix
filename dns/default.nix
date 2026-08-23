{ pkgs }:
let
  renderer = import ./lib.nix { inherit (pkgs) lib; };
  config = renderer.render (import ./zones);
in
{
  inherit config;
  ir = pkgs.writeText "dnscontrol.json" (builtins.toJSON config);
}
