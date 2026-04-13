# roles/network/xray/transports/default.nix
#
# Transport registry: the single place where transport modules are registered.
# To add a new transport protocol: create a new file in this directory, then
# append one line to the `modules` list below.
#
# Consumers (server.nix, client.nix, relay.nix, subscriptions.nix) fold over
# the returned attrset — adding a protocol should not require edits anywhere
# else.
{ lib }:

let
  helpers = import ./lib.nix { inherit lib; };

  modules = [
    ./tcp.nix
    ./grpc.nix
    ./xhttp.nix
  ];

  loadModule =
    path:
    let
      m = import path { inherit lib helpers; };
    in
    lib.nameValuePair m.name m;
in
lib.listToAttrs (map loadModule modules)
