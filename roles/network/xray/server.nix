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
    ];

    services.xray = {
      enable = true;
      settings = xrayConfig;
    };
  };
}
