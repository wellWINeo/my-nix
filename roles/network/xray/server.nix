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

  # Shared Reality settings (privateKey injected at runtime)
  mkRealitySettings = sni: {
    target = "${sni}:443";
    serverNames = [ sni ];
    shortIds = secrets.xray.reality.shortIds or [ ];
  };

  # Template config with placeholder for private key.
  # Uses services.xray.settingsFile (not .settings) to avoid the
  # xray -test checkPhase which would reject the placeholder.
  xrayConfigTemplate = {
    log = {
      loglevel = "info";
    };

    inbounds =
      # TCP + Vision + Reality
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
          };
        }
      ]
      # gRPC + Reality
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
            realitySettings = mkRealitySettings cfg.vlessGrpc.sni;
            grpcSettings = {
              serviceName = cfg.vlessGrpc.serviceName;
            };
          };
        }
      ]
      # xHTTP + Reality
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

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = !(lib.hasPrefix "/" cfg.vlessGrpc.serviceName);
        message = "roles.xray-server.vlessGrpc.serviceName must not start with '/'";
      }
      {
        assertion = (secrets.xray.reality.shortIds or [ ]) != [ ];
        message = "secrets.xray.reality.shortIds must be set before deploying xray-server (add to secrets.json and run make lock)";
      }
      {
        assertion = cfg.vlessTcp.enable || cfg.vlessGrpc.enable || cfg.vlessXhttp.enable;
        message = "At least one xray-server transport must be enabled";
      }
    ];

    # nginx SNI routing: L4 proxy that reads TLS SNI and routes to
    # the correct xray inbound. Never terminates TLS.
    services.nginx = {
      enable = true;
      streamConfig =
        let
          enabledTransports =
            lib.optionals cfg.vlessTcp.enable [ { sni = cfg.vlessTcp.sni; port = vlessTcpPort; } ]
            ++ lib.optionals cfg.vlessGrpc.enable [ { sni = cfg.vlessGrpc.sni; port = vlessGrpcPort; } ]
            ++ lib.optionals cfg.vlessXhttp.enable [ { sni = cfg.vlessXhttp.sni; port = vlessXhttpPort; } ];
          defaultPort =
            if cfg.vlessTcp.enable then vlessTcpPort else (builtins.head enabledTransports).port;
        in
        ''
          map $ssl_preread_server_name $xray_backend {
          ${lib.concatMapStrings (t: "    ${t.sni}  127.0.0.1:${toString t.port};\n") enabledTransports}    default  127.0.0.1:${toString defaultPort};
          }

          server {
            listen 443;
            ssl_preread on;
            proxy_pass $xray_backend;
          }
        '';
    };

    systemd.services.xray = {
      description = "Xray Reality Daemon";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      path = [
        pkgs.xray
        pkgs.jq
      ];
      serviceConfig = {
        PrivateTmp = true;
        LoadCredential = "private-key:${cfg.reality.privateKeyFile}";
        DynamicUser = true;
        CapabilityBoundingSet = "CAP_NET_ADMIN CAP_NET_BIND_SERVICE";
        AmbientCapabilities = "CAP_NET_ADMIN CAP_NET_BIND_SERVICE";
        NoNewPrivileges = true;
      };
      script = ''
        cat ${configTemplateFile} \
          | jq --arg key "$(cat "$CREDENTIALS_DIRECTORY/private-key")" \
              '.inbounds[].streamSettings.realitySettings.privateKey = $key' \
          > /tmp/xray.json
        exec xray -config /tmp/xray.json
      '';
    };

    networking.firewall.allowedTCPPorts = [ 443 ];
  };
}
