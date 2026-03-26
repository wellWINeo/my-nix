# roles/network/xray/client.nix
#
# Defines roles.xray.client options. Runs its own xray process (independent
# from server/relay). Uses shared option helpers from options.nix.
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.roles.xray.client;
  opts = import ./options.nix { inherit lib; };

  # Build streamSettings for a given transport.
  mkStreamSettings =
    transport:
    let
      sni =
        if (transport.serverName or "") != "" then transport.serverName else cfg.reality.serverName;
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
  options.roles.xray.client = {
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

    reality = opts.mkRealityClientOptions { };

    vlessTcp = opts.mkVlessTcpOptions { includeConnection = true; };
    vlessGrpc = opts.mkVlessGrpcOptions { includeConnection = true; };
    vlessXhttp = opts.mkVlessXhttpOptions { includeConnection = true; };
  };

  config = mkIf (config.roles.xray.enable && cfg.enable) {
    assertions = [
      {
        assertion = cfg.vlessTcp.enable || cfg.vlessGrpc.enable || cfg.vlessXhttp.enable;
        message = "At least one xray client outbound must be enabled";
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
        message = "roles.xray.client.reality.publicKey, shortId, serverName, and fingerprint must be set when reality.enable = true";
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
