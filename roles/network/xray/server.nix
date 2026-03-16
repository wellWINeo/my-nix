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

  vlessWsPort = 9000;
  vlessGrpcPort = 9001;

  xrayConfig = {
    log = {
      loglevel = "info";
    };

    inbounds =
      lib.optionals cfg.vlessWs.enable [
        {
          listen = "127.0.0.1";
          port = vlessWsPort;
          protocol = "vless";
          tag = "vless-ws-in";
          settings = {
            clients = map (u: {
              id = u.uuid;
              email = "${u.name}@xray";
            }) secrets.singBoxUsers;
            decryption = "none";
          };
          streamSettings = {
            network = "ws";
            security = "none";
            wsSettings = {
              path = cfg.vlessWs.path;
            };
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
            clients = map (u: {
              id = u.uuid;
              email = "${u.name}@xray";
            }) secrets.singBoxUsers;
            decryption = "none";
          };
          streamSettings = {
            network = "grpc";
            security = "none";
            grpcSettings = {
              serviceName = cfg.vlessGrpc.serviceName;
            };
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
          inboundTag = lib.optionals cfg.vlessWs.enable [ "vless-ws-in" ]
            ++ lib.optionals cfg.vlessGrpc.enable [ "vless-grpc-in" ];
          outboundTag = "direct-out";
        }
      ];
    };
  };
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

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.vlessWs.enable || cfg.vlessGrpc.enable;
        message = "At least one xray inbound must be enabled";
      }
      {
        assertion = !(lib.hasPrefix "/" cfg.vlessGrpc.serviceName);
        message = "roles.xray-server.vlessGrpc.serviceName must not start with '/' (xray uses it as a gRPC service name, not a path)";
      }
    ];

    services.xray = {
      enable = true;
      settings = xrayConfig;
    };

    services.nginx = mkIf (cfg.vlessWs.enable || cfg.vlessGrpc.enable) {
      enable = true;

      virtualHosts."gw.${cfg.baseDomain}" = {
        http2 = true;
        forceSSL = true;
        enableACME = false;

        sslCertificate = "/var/lib/acme/${cfg.baseDomain}/fullchain.pem";
        sslCertificateKey = "/var/lib/acme/${cfg.baseDomain}/key.pem";

        locations.${cfg.vlessWs.path} = mkIf cfg.vlessWs.enable {
          proxyPass = "http://127.0.0.1:${toString vlessWsPort}";
          proxyWebsockets = true;
          recommendedProxySettings = true;
        };

        locations."/${cfg.vlessGrpc.serviceName}" = mkIf cfg.vlessGrpc.enable {
          extraConfig = ''
            grpc_pass grpc://127.0.0.1:${toString vlessGrpcPort};
            grpc_set_header Host $host;
            grpc_set_header X-Real-IP $remote_addr;
          '';
        };

        locations."/" = mkIf cfg.enableFallback {
          return = "301 https://${cfg.baseDomain}$request_uri";
        };
      };
    };
  };
}
