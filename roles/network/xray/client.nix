{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.roles.xray-client;

  xrayConfig = {
    log = {
      loglevel = "info";
    };

    inbounds = [
      {
        listen = "0.0.0.0";
        port = cfg.port;
        protocol = "socks";
        tag = "socks-in";
        settings = {
          auth = "noauth";
          udp = true;
        };
      }
    ];

    outbounds =
      lib.optionals cfg.vlessWs.enable [
        {
          protocol = "vless";
          tag = "vless-ws-out";
          settings = {
            vnext = [
              {
                address = cfg.vlessWs.server;
                port = cfg.vlessWs.port;
                users = [
                  {
                    id = cfg.vlessWs.auth.uuid;
                    encryption = "none";
                  }
                ];
              }
            ];
          };
          streamSettings = {
            network = "ws";
            security = "tls";
            tlsSettings = {
              serverName = cfg.vlessWs.server;
            };
            wsSettings = {
              path = cfg.vlessWs.path;
            };
          };
        }
      ]
      ++ lib.optionals cfg.vlessGrpc.enable [
        {
          protocol = "vless";
          tag = "vless-grpc-out";
          settings = {
            vnext = [
              {
                address = cfg.vlessGrpc.server;
                port = cfg.vlessGrpc.port;
                users = [
                  {
                    id = cfg.vlessGrpc.auth.uuid;
                    encryption = "none";
                  }
                ];
              }
            ];
          };
          streamSettings = {
            network = "grpc";
            security = "tls";
            tlsSettings = {
              serverName = cfg.vlessGrpc.server;
            };
            grpcSettings = {
              serviceName = cfg.vlessGrpc.serviceName;
            };
          };
        }
      ];

    routing = {
      rules = [
        {
          type = "field";
          inboundTag = [ "socks-in" ];
          balancerTag = "proxy-balancer";
        }
      ];
      balancers = [
        {
          tag = "proxy-balancer";
          selector =
            lib.optionals cfg.vlessWs.enable [ "vless-ws-out" ]
            ++ lib.optionals cfg.vlessGrpc.enable [ "vless-grpc-out" ];
          strategy = {
            type = "random";
          };
        }
      ];
    };
  };
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

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.vlessWs.enable || cfg.vlessGrpc.enable;
        message = "At least one xray outbound must be enabled";
      }
    ];

    services.xray = {
      enable = true;
      settings = xrayConfig;
    };

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ];
  };
}
