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
  # When reality.enable = true, uses Reality TLS with per-transport or shared SNI.
  # When false, uses regular TLS with serverName from the transport.
  # Note: transport.server is only used in the TLS (non-Reality) branch;
  # it is silently ignored when Reality is enabled.
  mkStreamSettings =
    transport:
    let
      sni = if (transport.serverName or "") != "" then transport.serverName else cfg.reality.serverName;
      securitySettings =
        if cfg.reality.enable then
          {
            security = "reality";
            realitySettings = {
              publicKey = cfg.reality.publicKey;
              shortId = cfg.reality.shortId;
              serverName = sni;
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
      # Merge: `extra` keys win over `securitySettings` keys if there is a collision.
      # Callers must not pass `security`, `realitySettings`, or `tlsSettings` in `extra`.
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
                    # Vision flow: ONLY set on direct TCP; never on gRPC/xHTTP
                    flow = "xtls-rprx-vision";
                    encryption = "none";
                  }
                ];
              }
            ];
          };
          streamSettings = mkStreamSettings {
            server = cfg.vlessTcp.server;
            serverName = cfg.vlessTcp.serverName;
            extra = {
              network = "tcp";
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
            serverName = cfg.vlessGrpc.serverName;
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
            serverName = cfg.vlessXhttp.serverName;
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
        description = "SNI to present during TLS handshake (used when transport doesn't override serverName)";
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
          default = "";
          description = "Username (informational only; xray VLESS uses UUID)";
        };
        uuid = mkOption {
          type = types.str;
          description = "UUID for authentication";
        };
      };

      serverName = mkOption {
        type = types.str;
        default = "";
        description = "Reality SNI for this transport (overrides shared reality.serverName)";
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
          default = "";
          description = "Username (kept for parity; unused in xray VLESS config)";
        };
        uuid = mkOption {
          type = types.str;
          description = "UUID for authentication";
        };
      };

      serviceName = mkOption {
        type = types.str;
        default = "VlGrpc";
        description = "gRPC service name (must match server)";
      };

      serverName = mkOption {
        type = types.str;
        default = "";
        description = "Reality SNI for this transport (overrides shared reality.serverName)";
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
          default = "";
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

      serverName = mkOption {
        type = types.str;
        default = "";
        description = "Reality SNI for this transport (overrides shared reality.serverName)";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.vlessTcp.enable || cfg.vlessGrpc.enable || cfg.vlessXhttp.enable;
        message = "At least one xray-client outbound must be enabled";
      }
      {
        assertion =
          !cfg.reality.enable
          || (
            cfg.reality.publicKey != ""
            && cfg.reality.shortId != ""
            && cfg.reality.serverName != ""
            && cfg.reality.fingerprint != ""
          );
        message = "roles.xray-client.reality.publicKey, shortId, serverName, and fingerprint must be set when reality.enable = true";
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
