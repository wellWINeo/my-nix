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
  vlessXhttpPort = 9002;

  # Template config with placeholder for private key.
  # Uses services.xray.settingsFile (not .settings) to avoid the
  # xray -test checkPhase which would reject the placeholder.
  xrayConfigTemplate = {
    log = {
      loglevel = "info";
    };

    inbounds = [
      # Main inbound: VLESS + Reality on port 443.
      # Handles direct TCP+Vision connections; fallbacks route
      # WS/gRPC/xHTTP to internal sub-inbounds.
      {
        port = 443;
        protocol = "vless";
        tag = "vless-reality-in";
        settings = {
          clients = map (u: {
            id = u.uuid;
            flow = "xtls-rprx-vision";
            email = "${u.name}@xray";
          }) secrets.singBoxUsers;
          decryption = "none";
          fallbacks =
            lib.optionals cfg.vlessWs.enable [
              {
                path = cfg.vlessWs.path;
                dest = vlessWsPort;
                xver = 1;
              }
            ]
            ++ lib.optionals cfg.vlessGrpc.enable [
              {
                path = "/${cfg.vlessGrpc.serviceName}";
                dest = vlessGrpcPort;
                xver = 1;
              }
            ]
            ++ lib.optionals cfg.vlessXhttp.enable [
              {
                path = cfg.vlessXhttp.path;
                dest = vlessXhttpPort;
                xver = 1;
              }
            ];
        };
        streamSettings = {
          network = "tcp";
          security = "reality";
          realitySettings = {
            target = "${cfg.reality.fakeSni}:443";
            serverNames = [ cfg.reality.fakeSni ];
            # Placeholder replaced at activation time by system.activationScripts.xray-config
            privateKey = "__XRAY_PRIVATE_KEY__";
            # `or []` safe default if field missing from secrets.json
            shortIds = secrets.xrayRealityShortIds or [ ];
          };
        };
      }
    ]
    # Internal WS sub-inbound (only created when vlessWs is enabled)
    ++ lib.optionals cfg.vlessWs.enable [
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
          sockopt = {
            acceptProxyProtocol = true;
          };
        };
      }
    ]
    # Internal gRPC sub-inbound
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
          sockopt = {
            acceptProxyProtocol = true;
          };
        };
      }
    ]
    # Internal xHTTP sub-inbound
    ++ lib.optionals cfg.vlessXhttp.enable [
      {
        listen = "127.0.0.1";
        port = vlessXhttpPort;
        protocol = "vless";
        tag = "vless-xhttp-in";
        settings = {
          clients = map (u: {
            id = u.uuid;
            email = "${u.name}@xray";
          }) secrets.singBoxUsers;
          decryption = "none";
        };
        streamSettings = {
          network = "xhttp";
          security = "none";
          xhttpSettings = {
            path = cfg.vlessXhttp.path;
          };
          sockopt = {
            acceptProxyProtocol = true;
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
          inboundTag = [
            "vless-reality-in"
          ]
          ++ lib.optionals cfg.vlessWs.enable [ "vless-ws-in" ]
          ++ lib.optionals cfg.vlessGrpc.enable [ "vless-grpc-in" ]
          ++ lib.optionals cfg.vlessXhttp.enable [ "vless-xhttp-in" ];
          outboundTag = "direct-out";
        }
      ];
    };
  };

  configTemplateFile = pkgs.writeText "xray-config-template.json" (
    builtins.toJSON xrayConfigTemplate
  );
in
{
  options.roles.xray-server = {
    enable = mkEnableOption "xray anti-censorship proxy server with Reality";

    reality = {
      privateKeyFile = mkOption {
        type = types.path;
        description = "Path to the Reality private key file on disk (not stored in Nix store)";
        example = "/etc/nixos/secrets/xray-reality-private-key";
      };

      fakeSni = mkOption {
        type = types.str;
        default = "api.oneme.ru";
        description = "Target server to impersonate (fake SNI). Unauthorized connections are forwarded here.";
      };
    };

    vlessWs = {
      enable = mkEnableOption "VLESS over WebSocket";
      path = mkOption {
        type = types.str;
        default = "/vl-ws";
        description = "WebSocket path";
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

    vlessXhttp = {
      enable = mkEnableOption "VLESS over xHTTP";
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
        assertion = !(lib.hasPrefix "/" cfg.vlessGrpc.serviceName);
        message = "roles.xray-server.vlessGrpc.serviceName must not start with '/'";
      }
    ];

    # Write template to /etc/xray/config.json at activation time,
    # injecting the private key from disk (never stored in Nix store).
    system.activationScripts.xray-config = {
      text = ''
        install -d -m 700 /etc/xray
        key=$(cat ${lib.escapeShellArg (toString cfg.reality.privateKeyFile)})
        ${pkgs.jq}/bin/jq --arg key "$key" \
          '.inbounds[0].streamSettings.realitySettings.privateKey = $key' \
          ${configTemplateFile} > /etc/xray/config.json
        chmod 600 /etc/xray/config.json
        chown root:root /etc/xray/config.json
      '';
      deps = [ ];
    };

    services.xray = {
      enable = true;
      settingsFile = "/etc/xray/config.json";
    };

    networking.firewall.allowedTCPPorts = [ 443 ];
  };
}
