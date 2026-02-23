{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.roles.sing-box-client;

  singBoxConfig = {
    log = {
      level = "info";
      output = "stdout";
    };

    inbounds = [
      {
        type = "socks";
        tag = "socks-in";
        listen = "0.0.0.0";
        listen_port = cfg.port;
      }
    ];

    outbounds =
      lib.optionals cfg.vlessWs.enable [
        {
          type = "vless";
          tag = "vless-ws-out";
          server = cfg.vlessWs.server;
          server_port = cfg.vlessWs.port;
          uuid = cfg.vlessWs.auth.uuid;
          transport = {
            type = "ws";
            path = cfg.vlessWs.path;
          };
          tls = {
            enabled = true;
            server_name = cfg.vlessWs.server;
          };
        }
      ]
      ++ lib.optionals cfg.vlessGrpc.enable [
        {
          type = "vless";
          tag = "vless-grpc-out";
          server = cfg.vlessGrpc.server;
          server_port = cfg.vlessGrpc.port;
          uuid = cfg.vlessGrpc.auth.uuid;
          transport = {
            type = "grpc";
            service_name = cfg.vlessGrpc.serviceName;
          };
          tls = {
            enabled = true;
            server_name = cfg.vlessGrpc.server;
          };
        }
      ]
      ++ [
        {
          type = "urltest";
          tag = "proxy-out";
          outbounds =
            lib.optionals cfg.vlessWs.enable [ "vless-ws-out" ]
            ++ lib.optionals cfg.vlessGrpc.enable [ "vless-grpc-out" ];
          url = "https://www.gstatic.com/generate_204";
          interval = "5m";
          tolerance = 80;
        }
      ];

    route = {
      final = "proxy-out";
    };
  };
in
{
  options.roles.sing-box-client = {
    enable = mkEnableOption "sing-box proxy client";

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
          description = "Username for authentication";
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
          description = "Username for authentication";
        };

        uuid = mkOption {
          type = types.str;
          description = "UUID for authentication";
        };
      };

      serviceName = mkOption {
        type = types.str;
        default = "VlGrpc";
        description = "gRPC service name";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.vlessWs.enable || cfg.vlessGrpc.enable;
        message = "At least one sing-box outbound must be enabled";
      }
    ];

    services.sing-box = {
      enable = true;
      settings = singBoxConfig;
    };

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ];
  };
}
