# roles/network/xray/default.nix
#
# Coordinator: imports server/client/relay sub-modules, merges their config
# fragments, and owns systemd configuration. SNI routing delegated to sni-router.
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
  };

  serverCfg = config.roles.xray.server;
  relayCfg = config.roles.xray.relay;

  serverConfig = if cfg.server.enable then cfg._serverConfig else emptyConfig;
  relayConfig = if cfg.relay.enable then cfg._relayConfig else emptyConfig;

  # Port constants (must match server.nix / relay.nix)
  vlessTcpPort = 9000;
  vlessGrpcPort = 9001;
  vlessXhttpPort = 9002;
  relayTcpPort = 9010;
  relayGrpcPort = 9011;
  relayXhttpPort = 9012;

  # Build sni-router entries from enabled transports
  serverSniEntries =
    lib.optionals serverCfg.vlessTcp.enable [
      { sni = serverCfg.vlessTcp.sni; backend = "127.0.0.1:${toString vlessTcpPort}"; }
    ]
    ++ lib.optionals serverCfg.vlessGrpc.enable [
      { sni = serverCfg.vlessGrpc.sni; backend = "127.0.0.1:${toString vlessGrpcPort}"; }
    ]
    ++ lib.optionals serverCfg.vlessXhttp.enable [
      { sni = serverCfg.vlessXhttp.sni; backend = "127.0.0.1:${toString vlessXhttpPort}"; }
    ];

  relaySniEntries =
    lib.optionals (relayCfg.enable && serverCfg.vlessTcp.enable) [
      { sni = relayCfg.vlessTcp.sni; backend = "127.0.0.1:${toString relayTcpPort}"; }
    ]
    ++ lib.optionals (relayCfg.enable && serverCfg.vlessGrpc.enable) [
      { sni = relayCfg.vlessGrpc.sni; backend = "127.0.0.1:${toString relayGrpcPort}"; }
    ]
    ++ lib.optionals (relayCfg.enable && serverCfg.vlessXhttp.enable) [
      { sni = relayCfg.vlessXhttp.sni; backend = "127.0.0.1:${toString relayXhttpPort}"; }
    ];

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
    ../sni-router.nix
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

    # SNI routing (server/relay mode only)
    roles.sni-router = mkIf cfg.server.enable {
      enable = true;
      entries = serverSniEntries ++ relaySniEntries;
    };

    # Xray systemd service (server/relay mode only)
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
  };
}
