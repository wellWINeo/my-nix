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

  singBoxConfig = {
    log = {
      level = "info";
      output = "stdout";
    };

    # VLESS protocols listen on localhost because nginx proxies them
    inbounds =
      lib.optionals cfg.vlessWs.enable [
        {
          type = "vless";
          tag = "vless-ws-in";
          listen = "127.0.0.1";
          listen_port = vlessWsPort;
          users = map (u: {
            name = u.name;
            uuid = u.uuid;
          }) secrets.singBoxUsers;
          transport = {
            type = "ws";
            path = cfg.vlessWs.path;
          };
        }
      ]
      ++ lib.optionals cfg.vlessGrpc.enable [
        {
          type = "vless";
          tag = "vless-grpc-in";
          listen = "127.0.0.1";
          listen_port = vlessGrpcPort;
          users = map (u: {
            name = u.name;
            uuid = u.uuid;
          }) secrets.singBoxUsers;
          transport = {
            type = "grpc";
            service_name = cfg.vlessGrpc.serviceName;
          };
        }
      ]
      ++ lib.optionals cfg.naive.enable [
        {
          type = "naive";
          tag = "naive-in";
          listen = "::";
          listen_port = naivePort;
          network = "udp";
          users = map (u: {
            username = u.name;
            password = u.password;
          }) secrets.singBoxUsers;
          tls = {
            enabled = true;
            server_name = "gw.${cfg.baseDomain}";
            certificate_path = "/var/lib/acme/${cfg.baseDomain}/fullchain.pem";
            key_path = "/var/lib/acme/${cfg.baseDomain}/key.pem";
          };
        }
      ];

    outbounds = [
      {
        type = "direct";
        tag = "direct-out";
      }
    ];

    route = {
      final = "direct-out";
    };
  };
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
        default = "/vl-grpc";
        description = "Service name with leading / (e.g., '/vl-grpc')";
      };
    };

    naive = {
      enable = mkEnableOption "NaiveProxy (QUIC on UDP 443)";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.vlessWs.enable || cfg.vlessGrpc.enable || cfg.naive.enable;
        message = "At least one sing-box inbound must be enabled";
      }
    ];

    services.sing-box = {
      enable = true;
      settings = singBoxConfig;
    };

    networking.firewall.allowedTCPPorts = lib.optionals (cfg.vlessWs.enable || cfg.vlessGrpc.enable) [
      443
    ];

    services.nginx = mkIf (cfg.vlessWs.enable || cfg.vlessGrpc.enable) {
      enable = true;

      virtualHosts."gw.${cfg.baseDomain}" = {
        forceSSL = true;
        enableACME = false;

        sslCertificate = "/var/lib/acme/${cfg.baseDomain}/fullchain.pem";
        sslCertificateKey = "/var/lib/acme/${cfg.baseDomain}/key.pem";

        locations.${cfg.vlessWs.path} = mkIf cfg.vlessWs.enable {
          proxyPass = "http://127.0.0.1:${toString vlessWsPort}";
          proxyWebsockets = true;
          recommendedProxySettings = true;
        };

        locations.${cfg.vlessGrpc.serviceName} = mkIf cfg.vlessGrpc.enable {
          extraConfig = ''
            grpc_pass grpc://127.0.0.1:${toString vlessGrpcPort};
            grpc_set_header Host $host;
            grpc_set_header X-Real-IP $remote_addr;
          '';
        };

        locations."/" = {
          return = "301 https://${cfg.baseDomain}$request_uri";
        };
      };
    };
  };
}
