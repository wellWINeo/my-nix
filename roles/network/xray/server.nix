# roles/network/xray/server.nix
#
# Defines roles.xray.server options and exports _serverConfig fragment.
# The coordinator (default.nix) owns systemd, nginx, and firewall.
{
  config,
  lib,
  ...
}:

with lib;

let
  cfg = config.roles.xray.server;
  secrets = import ../../../secrets;

  vlessTcpPort = 9000;
  vlessGrpcPort = 9001;
  vlessXhttpPort = 9002;

  # Clients with Vision flow (TCP only)
  vlessTcpClients = map (u: {
    id = u.uuid;
    flow = "xtls-rprx-vision";
    email = "${u.name}@xray";
  }) secrets.singBoxUsers;

  # Clients without flow (gRPC, xHTTP)
  vlessClients = map (u: {
    id = u.uuid;
    email = "${u.name}@xray";
  }) secrets.singBoxUsers;

  # Shared Reality settings (privateKey injected at runtime by coordinator)
  mkRealitySettings = sni: {
    target = "${sni}:443";
    serverNames = [ sni ];
    shortIds = secrets.xray.reality.shortIds or [ ];
  };

  serverConfig = {
    inbounds =
      lib.optionals cfg.vlessTcp.enable [
        {
          listen = "127.0.0.1";
          port = vlessTcpPort;
          protocol = "vless";
          tag = "vless-tcp-in";
          settings = {
            clients = vlessTcpClients;
            decryption = "none";
          };
          streamSettings = {
            network = "tcp";
            security = "reality";
            realitySettings = mkRealitySettings cfg.vlessTcp.sni;
            sockopt.acceptProxyProtocol = true;
          };
        }
      ]
      ++ lib.optionals cfg.vlessGrpc.enable [
        {
          listen = "127.0.0.1";
          port = vlessGrpcPort;
          protocol = "vless";
          tag = "vless-grpc-in";
          settings = {
            clients = vlessClients;
            decryption = "none";
          };
          streamSettings = {
            network = "grpc";
            security = "reality";
            realitySettings = (mkRealitySettings cfg.vlessGrpc.sni) // {
              alpn = [ "h2" ];
            };
            grpcSettings = {
              serviceName = cfg.vlessGrpc.serviceName;
            };
            sockopt.acceptProxyProtocol = true;
          };
        }
      ]
      ++ lib.optionals cfg.vlessXhttp.enable [
        {
          listen = "127.0.0.1";
          port = vlessXhttpPort;
          protocol = "vless";
          tag = "vless-xhttp-in";
          settings = {
            clients = vlessClients;
            decryption = "none";
          };
          streamSettings = {
            network = "xhttp";
            security = "reality";
            realitySettings = mkRealitySettings cfg.vlessXhttp.sni;
            xhttpSettings = {
              path = cfg.vlessXhttp.path;
            };
            sockopt.acceptProxyProtocol = true;
          };
        }
      ];

    outbounds = [
      {
        protocol = "freedom";
        tag = "direct-out";
      }
    ];

    routing = {
      rules = [
        {
          type = "field";
          inboundTag =
            lib.optionals cfg.vlessTcp.enable [ "vless-tcp-in" ]
            ++ lib.optionals cfg.vlessGrpc.enable [ "vless-grpc-in" ]
            ++ lib.optionals cfg.vlessXhttp.enable [ "vless-xhttp-in" ];
          outboundTag = "direct-out";
        }
      ];
      balancers = [ ];
    };

    nginxSniEntries =
      lib.optionals cfg.vlessTcp.enable [
        {
          sni = cfg.vlessTcp.sni;
          port = vlessTcpPort;
        }
      ]
      ++ lib.optionals cfg.vlessGrpc.enable [
        {
          sni = cfg.vlessGrpc.sni;
          port = vlessGrpcPort;
        }
      ]
      ++ lib.optionals cfg.vlessXhttp.enable [
        {
          sni = cfg.vlessXhttp.sni;
          port = vlessXhttpPort;
        }
      ];
  };
in
{
  options.roles.xray.server = {
    enable = mkEnableOption "xray anti-censorship proxy server with Reality";

    reality = {
      privateKeyFile = mkOption {
        type = types.path;
        description = "Path to the Reality private key file on disk (not stored in Nix store)";
        example = "/etc/nixos/secrets/xray-reality-private-key";
      };
    };

    vlessTcp = {
      enable = mkEnableOption "VLESS over direct TCP with Vision flow";
      sni = mkOption {
        type = types.str;
        default = "api.oneme.ru";
        description = "Reality SNI and camouflage target for TCP+Vision transport";
      };
    };

    vlessGrpc = {
      enable = mkEnableOption "VLESS over gRPC";
      sni = mkOption {
        type = types.str;
        default = "avatars.mds.yandex.net";
        description = "Reality SNI and camouflage target for gRPC transport";
      };
      serviceName = mkOption {
        type = types.str;
        default = "VlGrpc";
        description = "gRPC service name (no leading slash)";
      };
    };

    vlessXhttp = {
      enable = mkEnableOption "VLESS over xHTTP";
      sni = mkOption {
        type = types.str;
        default = "onlymir.ru";
        description = "Reality SNI and camouflage target for xHTTP transport";
      };
      path = mkOption {
        type = types.str;
        default = "/vl-xhttp";
        description = "xHTTP path";
      };
    };
  };

  config = mkIf (config.roles.xray.enable && cfg.enable) {
    assertions = [
      {
        assertion = !(lib.hasPrefix "/" cfg.vlessGrpc.serviceName);
        message = "roles.xray.server.vlessGrpc.serviceName must not start with '/'";
      }
      {
        assertion = (secrets.xray.reality.shortIds or [ ]) != [ ];
        message = "secrets.xray.reality.shortIds must be set before deploying xray server";
      }
      {
        assertion = cfg.vlessTcp.enable || cfg.vlessGrpc.enable || cfg.vlessXhttp.enable;
        message = "At least one xray server transport must be enabled";
      }
    ];

    roles.xray._serverConfig = serverConfig;
  };
}
