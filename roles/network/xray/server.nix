{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.roles.xray-server;
  secrets = import ../../../secrets;
in
{
  options.roles.xray-server = {
    enable = mkEnableOption "xray anti-censorship proxy server";

    baseDomain = mkOption {
      type = types.str;
      description = "Base domain for certificates and hostnames";
    };

    vlessWs = {
      enable = mkEnableOption "VLESS over WebSocket";
      path = mkOption {
        type = types.str;
        default = "/vl-ws";
      };
    };

    vlessGrpc = {
      enable = mkEnableOption "VLESS over gRPC";
      serviceName = mkOption {
        type = types.str;
        default = "vl-grpc";
        description = "gRPC service name (no leading slash)";
      };
    };

    enableFallback = mkEnableOption "Enable fallback redirect";
  };
}
