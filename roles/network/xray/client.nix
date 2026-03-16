{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.roles.xray-client;
in
{
  options.roles.xray-client = {
    enable = mkEnableOption "xray proxy client";

    port = mkOption {
      type = types.port;
      default = 1081;
      description = "SOCKS5 listen port";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open firewall for SOCKS port";
    };

    vlessWs = {
      enable = mkEnableOption "VLESS over WebSocket";

      server = mkOption {
        type = types.str;
        description = "Server domain (e.g., gw.uspenskiy.su)";
      };

      port = mkOption {
        type = types.port;
        default = 443;
        description = "Server port";
      };

      auth = {
        name = mkOption {
          type = types.str;
          description = "Username (kept for sing-box parity; not used in xray VLESS config)";
        };

        uuid = mkOption {
          type = types.str;
          description = "UUID for authentication";
        };
      };

      path = mkOption {
        type = types.str;
        default = "/vl-ws";
        description = "WebSocket path";
      };
    };

    vlessGrpc = {
      enable = mkEnableOption "VLESS over gRPC";

      server = mkOption {
        type = types.str;
        description = "Server domain (e.g., gw.uspenskiy.su)";
      };

      port = mkOption {
        type = types.port;
        default = 443;
        description = "Server port";
      };

      auth = {
        name = mkOption {
          type = types.str;
          description = "Username (kept for sing-box parity; not used in xray VLESS config)";
        };

        uuid = mkOption {
          type = types.str;
          description = "UUID for authentication";
        };
      };

      serviceName = mkOption {
        type = types.str;
        default = "vl-grpc";
        description = "gRPC service name (must match server)";
      };
    };
  };

  # Note: auth.name options are kept for sing-box parity but are unused
  # in the xray config — xray VLESS only uses UUID for authentication.
}
