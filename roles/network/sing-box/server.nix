{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.roles.sing-box-server;
  secrets = import ../../secrets;

  vlessWsPort = 9000;
  vlessGrpcPort = 9001;
  naivePort = 443;
in
{
  options.roles.sing-box-server = {
    enable = mkEnableOption "sing-box anti-censorship proxy server";

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
      };
    };

    naive = {
      enable = mkEnableOption "NaiveProxy (QUIC on UDP 443)";
    };
  };

  config = mkIf cfg.enable {
  };
}
