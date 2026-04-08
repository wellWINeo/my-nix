# roles/network/xray/default.nix
#
# Coordinator: imports server/client/relay sub-modules, merges their config
# fragments, and owns systemd, nginx, and firewall configuration.
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.roles.xray;

  emptyConfig = {
    inbounds = [ ];
    outbounds = [ ];
    routing = {
      rules = [ ];
      balancers = [ ];
    };
    nginxSniEntries = [ ];
  };

  serverConfig = if cfg.server.enable then cfg._serverConfig else emptyConfig;
  relayConfig = if cfg.relay.enable then cfg._relayConfig else emptyConfig;

  subsCfg = config.roles.xray.subscriptions;
  subsCoLocated = cfg.server.enable && subsCfg.enable;
  subsStreamEntry = lib.optionals subsCoLocated [
    {
      sni = subsCfg.sni;
      port = 8444;
    }
  ];
  allNginxEntries = serverConfig.nginxSniEntries ++ relayConfig.nginxSniEntries ++ subsStreamEntry;

  xrayConfigTemplate = {
    log = {
      loglevel = "info";
    };
    inbounds = serverConfig.inbounds ++ relayConfig.inbounds;
    outbounds = serverConfig.outbounds ++ relayConfig.outbounds;
    routing = {
      rules = serverConfig.routing.rules ++ relayConfig.routing.rules;
      balancers = serverConfig.routing.balancers ++ relayConfig.routing.balancers;
    };
  };

  configTemplateFile = pkgs.writeText "xray-config-template.json" (
    builtins.toJSON xrayConfigTemplate
  );
in
{
  imports = [
    ./server.nix
    ./client.nix
    ./relay.nix
    ./subscriptions.nix
  ];

  options.roles.xray = {
    enable = mkEnableOption "xray proxy";

    _serverConfig = mkOption {
      type = types.attrs;
      internal = true;
      default = emptyConfig;
      description = "Config fragment exported by server.nix";
    };

    _relayConfig = mkOption {
      type = types.attrs;
      internal = true;
      default = emptyConfig;
      description = "Config fragment exported by relay.nix";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.server.enable || cfg.client.enable;
        message = "roles.xray requires at least server or client to be enabled";
      }
      {
        assertion = !(cfg.server.enable && cfg.client.enable);
        message = "roles.xray.server and roles.xray.client cannot be enabled on the same host";
      }
    ];

    # Server/relay: systemd service, nginx, firewall
    # (only when server is enabled; client uses services.xray independently)
    services.nginx = mkIf (cfg.server.enable || subsCoLocated) {
      enable = true;
      streamConfig =
        let
          defaultPort = if allNginxEntries != [ ] then (builtins.head allNginxEntries).port else 9000;
        in
        ''
          map $ssl_preread_server_name $xray_backend {
          ${
            lib.concatMapStrings (t: "    ${t.sni}  127.0.0.1:${toString t.port};\n") allNginxEntries
          }    default  127.0.0.1:${toString defaultPort};
          }

          server {
            listen 443;
            ssl_preread on;
            proxy_pass $xray_backend;
            proxy_protocol on;
          }
        '';
    };

    systemd.services.xray = mkIf cfg.server.enable {
      description = "Xray Reality Daemon";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      path = [
        pkgs.xray
        pkgs.jq
      ];
      serviceConfig = {
        PrivateTmp = true;
        LoadCredential = "private-key:${cfg.server.reality.privateKeyFile}";
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

    networking.firewall.allowedTCPPorts = mkIf cfg.server.enable [ 443 ];
  };
}
