{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.roles.xray-client;

  # Build streamSettings for a given transport.
  # When reality.enable = true, uses Reality TLS with shared settings.
  # When false, uses regular TLS with serverName from the transport.
  # Note: transport.server is only used in the TLS (non-Reality) branch;
  # it is silently ignored when Reality is enabled.
  mkStreamSettings =
    transport:
    let
      securitySettings =
        if cfg.reality.enable then
          {
            security = "reality";
            realitySettings = {
              publicKey = cfg.reality.publicKey;
              shortId = cfg.reality.shortId;
              serverName = cfg.reality.serverName;
              fingerprint = cfg.reality.fingerprint;
            };
          }
        else
          {
            security = "tls";
            tlsSettings = {
              serverName = transport.server;
            };
          };
    in
    securitySettings // transport.extra;

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
      # Direct TCP + Vision: only valid with Reality TLS (Vision requires direct TLS, not framed transport)
      lib.optionals cfg.vlessTcp.enable [
        {
          protocol = "vless";
          tag = "vless-tcp-out";
          settings = {
            vnext = [
              {
                address = cfg.vlessTcp.server;
                port = cfg.vlessTcp.port;
                users = [
                  {
                    id = cfg.vlessTcp.auth.uuid;
                    # Vision flow: ONLY set on direct TCP; never on WS/gRPC/xHTTP
                    flow = "xtls-rprx-vision";
                    encryption = "none";
                  }
                ];
              }
            ];
          };
          streamSettings = mkStreamSettings {
            server = cfg.vlessTcp.server;
            extra = {
              network = "tcp";
            };
          };
        }
      ]
      ++ lib.optionals cfg.vlessWs.enable [
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
                    # No flow for WS — framed transport, Vision not applicable
                    encryption = "none";
                  }
                ];
              }
            ];
          };
          streamSettings = mkStreamSettings {
            server = cfg.vlessWs.server;
            extra = {
              network = "ws";
              wsSettings = {
                path = cfg.vlessWs.path;
              };
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
          streamSettings = mkStreamSettings {
            server = cfg.vlessGrpc.server;
            extra = {
              network = "grpc";
              grpcSettings = {
                serviceName = cfg.vlessGrpc.serviceName;
              };
            };
          };
        }
      ]
      ++ lib.optionals cfg.vlessXhttp.enable [
        {
          protocol = "vless";
          tag = "vless-xhttp-out";
          settings = {
            vnext = [
              {
                address = cfg.vlessXhttp.server;
                port = cfg.vlessXhttp.port;
                users = [
                  {
                    id = cfg.vlessXhttp.auth.uuid;
                    encryption = "none";
                  }
                ];
              }
            ];
          };
          streamSettings = mkStreamSettings {
            server = cfg.vlessXhttp.server;
            extra = {
              network = "xhttp";
              xhttpSettings = {
                path = cfg.vlessXhttp.path;
              };
            };
          };
        }
      ]
      ++ [
        {
          protocol = "freedom";
          tag = "direct-out";
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
            lib.optionals cfg.vlessTcp.enable [ "vless-tcp-out" ]
            ++ lib.optionals cfg.vlessWs.enable [ "vless-ws-out" ]
            ++ lib.optionals cfg.vlessGrpc.enable [ "vless-grpc-out" ]
            ++ lib.optionals cfg.vlessXhttp.enable [ "vless-xhttp-out" ];
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

    # Shared Reality settings — applies to all enabled outbounds when reality.enable = true.
    # When false, outbounds use regular TLS (backwards-compatible with nginx+TLS servers).
    reality = {
      enable = mkEnableOption "Reality TLS for all outbounds";

      publicKey = mkOption {
        type = types.str;
        default = "";
        description = "Server's Reality public key";
      };

      shortId = mkOption {
        type = types.str;
        default = "";
        description = "Authorized shortId for authentication";
      };

      serverName = mkOption {
        type = types.str;
        default = "api.oneme.ru";
        description = "SNI to present during TLS handshake";
      };

      fingerprint = mkOption {
        type = types.str;
        default = "chrome";
        description = "uTLS fingerprint to use (chrome, firefox, safari, etc.)";
      };
    };

    vlessTcp = {
      enable = mkEnableOption "VLESS over direct TCP with Vision flow";

      server = mkOption {
        type = types.str;
        description = "Server domain or IP";
      };

      port = mkOption {
        type = types.port;
        default = 443;
        description = "Server port";
      };

      auth = {
        name = mkOption {
          type = types.str;
          description = "Username (informational only; xray VLESS uses UUID)";
        };
        uuid = mkOption {
          type = types.str;
          description = "UUID for authentication";
        };
      };
    };

    vlessWs = {
      enable = mkEnableOption "VLESS over WebSocket";

      server = mkOption {
        type = types.str;
        description = "Server domain (e.g., veles IP or domain)";
      };

      port = mkOption {
        type = types.port;
        default = 443;
        description = "Server port";
      };

      auth = {
        name = mkOption {
          type = types.str;
          description = "Username (kept for parity; unused in xray VLESS config)";
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
        description = "Server domain";
      };

      port = mkOption {
        type = types.port;
        default = 443;
        description = "Server port";
      };

      auth = {
        name = mkOption {
          type = types.str;
          description = "Username (kept for parity; unused in xray VLESS config)";
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

    vlessXhttp = {
      enable = mkEnableOption "VLESS over xHTTP";

      server = mkOption {
        type = types.str;
        description = "Server domain";
      };

      port = mkOption {
        type = types.port;
        default = 443;
        description = "Server port";
      };

      auth = {
        name = mkOption {
          type = types.str;
          description = "Username (informational only)";
        };
        uuid = mkOption {
          type = types.str;
          description = "UUID for authentication";
        };
      };

      path = mkOption {
        type = types.str;
        default = "/vl-xhttp";
        description = "xHTTP path";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion =
          cfg.vlessTcp.enable || cfg.vlessWs.enable || cfg.vlessGrpc.enable || cfg.vlessXhttp.enable;
        message = "At least one xray-client outbound must be enabled";
      }
      {
        assertion =
          !cfg.reality.enable
          || (cfg.reality.publicKey != "" && cfg.reality.shortId != "" && cfg.reality.serverName != "");
        message = "roles.xray-client.reality.publicKey, shortId, and serverName must be set when reality.enable = true";
      }
    ];

    services.xray = {
      enable = true;
      settings = xrayConfig;
    };

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ];
    networking.firewall.allowedUDPPorts = mkIf cfg.openFirewall [ cfg.port ];
  };
}
