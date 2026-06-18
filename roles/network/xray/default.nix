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
    nginxSniEntries = [ ];
  };

  serverCfg = config.roles.xray.server;
  relayCfg = config.roles.xray.relay;
  subsCfg = config.roles.xray.subscriptions;

  serverHysteriaCfg = serverCfg.hysteria;
  hysteriaServerEnabled = cfg.server.enable && serverHysteriaCfg.enable;
  hysteriaRelayInboundEnabled = cfg.relay.enable && relayCfg.hysteria.enable;
  hysteriaInboundEnabled = hysteriaServerEnabled || hysteriaRelayInboundEnabled;

  serverConfig = if cfg.server.enable then cfg._serverConfig else emptyConfig;
  relayConfig = if cfg.relay.enable then cfg._relayConfig else emptyConfig;

  subsCoLocated = cfg.server.enable && subsCfg.enable;

  # Build sni-router entries from config fragments (port → backend address)
  serverSniEntries = map (e: {
    sni = e.sni;
    backend = "127.0.0.1:${toString e.port}";
  }) serverConfig.nginxSniEntries;
  relaySniEntries = map (e: {
    sni = e.sni;
    backend = "127.0.0.1:${toString e.port}";
  }) relayConfig.nginxSniEntries;
  subsSniEntries =
    if subsCoLocated then
      [
        {
          sni = subsCfg.sni;
          backend = "127.0.0.1:8444";
        }
      ]
    else
      [ ];

  hasBalancers = (serverConfig.routing.balancers ++ relayConfig.routing.balancers) != [ ];

  xrayConfigBase = {
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

  xrayConfigTemplate =
    xrayConfigBase
    // (optionalAttrs hasBalancers {
      observatory = {
        subjectSelector = [ "relay-" ];
        probeURL = "https://www.google.com/generate_204";
        probeInterval = "60s";
      };
    });

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
      entries = serverSniEntries ++ relaySniEntries ++ subsSniEntries;
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
        LoadCredential = [
          "private-key:${cfg.server.reality.privateKeyFile}"
        ]
        ++ lib.optional hysteriaServerEnabled "hysteria-cert:${serverHysteriaCfg.certFile}"
        ++ lib.optional hysteriaServerEnabled "hysteria-key:${serverHysteriaCfg.keyFile}"
        ++ lib.optional hysteriaRelayInboundEnabled "hysteria-relay-cert:${relayCfg.hysteria.certFile}"
        ++ lib.optional hysteriaRelayInboundEnabled "hysteria-relay-key:${relayCfg.hysteria.keyFile}";
        DynamicUser = true;
        CapabilityBoundingSet = "CAP_NET_ADMIN CAP_NET_BIND_SERVICE";
        AmbientCapabilities = "CAP_NET_ADMIN CAP_NET_BIND_SERVICE";
        NoNewPrivileges = true;
      };
      script =
        let
          realityStage = ''
            jq --arg key "$(cat "$CREDENTIALS_DIRECTORY/private-key")" \
              '.inbounds[] |= if (.streamSettings.security // "") == "reality"
                               then .streamSettings.realitySettings.privateKey = $key
                               else . end'
          '';
          hysteriaStage = lib.optionalString hysteriaInboundEnabled ''
            | jq \
                --arg cert "$CREDENTIALS_DIRECTORY/hysteria-cert" \
                --arg key "$CREDENTIALS_DIRECTORY/hysteria-key" \
                --arg rcert "$CREDENTIALS_DIRECTORY/hysteria-relay-cert" \
                --arg rkey "$CREDENTIALS_DIRECTORY/hysteria-relay-key" \
                '.inbounds[] |= if .protocol != "hysteria" then .
                                 elif .tag == "hy2-relay-in" then .streamSettings.tlsSettings.certificates[0] = {certificateFile: $rcert, keyFile: $rkey}
                                 else .streamSettings.tlsSettings.certificates[0] = {certificateFile: $cert, keyFile: $key} end'
          '';
        in
        ''
          cat ${configTemplateFile} \
            | ${realityStage} \
            ${hysteriaStage} \
            > /tmp/xray.json
          exec xray -config /tmp/xray.json
        '';
    };
  };
}
