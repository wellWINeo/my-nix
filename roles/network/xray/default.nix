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

  transportHelpers = import ./transports/lib.nix { inherit lib; };

  serverHysteriaCfg = serverCfg.hysteria;
  hysteriaServerEnabled = cfg.server.enable && serverHysteriaCfg.enable;
  hysteriaRelayInboundEnabled = cfg.relay.enable && relayCfg.hysteria.enable;
  hysteriaInboundEnabled = hysteriaServerEnabled || hysteriaRelayInboundEnabled;

  reverseEnabled = cfg.reverse.portal.enable || cfg.reverse.bridge.enable;

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

  # Buyan-initiated reverse link (bridge side). Uses the simplified VLESS
  # settings shape (address/port/id/encryption/reverse at the settings level):
  # Xray 26.9.9's VLESS parser rejects `reverse` inside the vnext[].users[]
  # shape, so this outbound must not use mkVnextOutbound.
  reverseBridgeOutbound =
    let
      outbound = {
        tag = "reverse-veles-client";
        protocol = "vless";
        settings = {
          address = cfg.reverse.bridge.address;
          port = 443;
          id = cfg.reverse.uuid;
          encryption = "none";
          reverse.tag = "reverse-veles-in";
        };
        streamSettings = {
          network = "xhttp";
          security = "reality";
          realitySettings = {
            publicKey = cfg.reverse.bridge.publicKey;
            shortId = cfg.reverse.bridge.shortId;
            serverName = cfg.reverse.bridge.serverName;
            fingerprint = "firefox";
          };
          xhttpSettings.path = cfg.reverse.bridge.path;
        };
      };
    in
    if cfg.fragmentClientHello then
      transportHelpers.withClientHelloFragmentation outbound
    else
      outbound;

  # Dedicated restricted egress for traffic arriving from the reverse link:
  # public TCP/UDP only; everything else stays blocked by Xray's
  # reverse-proxy default policy.
  reverseEgressOutbound = {
    protocol = "freedom";
    tag = "reverse-public-out";
    settings.finalRules = [
      {
        action = "allow";
        network = "tcp,udp";
        ip = [ "!geoip:private" ];
      }
    ];
  };

  reverseBridgeRoutingRules = [
    {
      type = "field";
      inboundTag = [ "reverse-veles-in" ];
      outboundTag = "reverse-public-out";
    }
  ];

  xrayConfigBase = {
    log = {
      loglevel = "info";
    };
    inbounds = serverConfig.inbounds ++ relayConfig.inbounds;
    outbounds =
      serverConfig.outbounds
      ++ relayConfig.outbounds
      ++ optionals cfg.reverse.bridge.enable [
        reverseBridgeOutbound
        reverseEgressOutbound
      ];
    routing = {
      rules =
        serverConfig.routing.rules
        ++ relayConfig.routing.rules
        ++ optionals cfg.reverse.bridge.enable reverseBridgeRoutingRules;
      balancers = serverConfig.routing.balancers ++ relayConfig.routing.balancers;
    };
  };

  xrayConfigTemplate =
    xrayConfigBase
    // (optionalAttrs hasBalancers {
      observatory = {
        # Portal hosts also observe the dynamically registered Buyan-initiated
        # reverse outbound so reverse-first fallback can exclude it when dead.
        subjectSelector = [ "relay-" ] ++ lib.optional cfg.reverse.portal.enable "reverse-buyan-out";
        probeURL = "https://www.google.com/generate_204";
        probeInterval = "60s";
      };
    })
    // cfg._extraConfig;

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
    ./metrics.nix
    ../sni-router.nix
  ];

  options.roles.xray = {
    enable = mkEnableOption "xray proxy";

    fragmentClientHello = mkOption {
      type = types.bool;
      default = true;
      description = "Fragment ClientHello messages on outgoing VLESS connections";
    };

    _serverConfig = mkOption {
      type = types.attrs;
      internal = true;
      default = emptyConfig;
      description = "Config fragment exported by server.nix";
    };

    _extraConfig = mkOption {
      type = types.attrs;
      internal = true;
      default = { };
      description = "Extra top-level config keys merged into the xray config";
    };

    _relayConfig = mkOption {
      type = types.attrs;
      internal = true;
      default = emptyConfig;
      description = "Config fragment exported by relay.nix";
    };

    _configTemplate = mkOption {
      type = types.attrs;
      internal = true;
      default = { };
      description = "The exact config template JSON passed to pkgs.writeText (before runtime credential injection)";
    };

    reverse = {
      portal.enable = mkEnableOption "dedicated Buyan-initiated reverse portal";

      bridge = {
        enable = mkEnableOption "Buyan reverse bridge";

        address = mkOption {
          type = types.str;
          description = "Veles address Buyan dials for the reverse link (Buyan reverse-link target setting)";
        };

        serverName = mkOption {
          type = types.str;
          description = "REALITY SNI for the reverse link; must match the Veles server xHTTP inbound SNI (Buyan reverse-link target setting)";
        };

        publicKey = mkOption {
          type = types.str;
          description = "Veles REALITY public key authenticating the reverse link (Buyan reverse-link target setting)";
        };

        shortId = mkOption {
          type = types.str;
          description = "Authorized REALITY short ID for the reverse link (Buyan reverse-link target setting)";
        };

        path = mkOption {
          type = types.str;
          default = "/vl-xhttp";
          description = "Veles server xHTTP path";
        };
      };

      uuid = mkOption {
        type = types.str;
        default = "";
        description = "UUID of the Veles-authorized buyan user for the reverse link";
      };
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
      {
        assertion = !(cfg.reverse.portal.enable && cfg.reverse.bridge.enable);
        message = "roles.xray.reverse.portal and roles.xray.reverse.bridge cannot be enabled on the same host";
      }
      {
        assertion =
          !reverseEnabled
          ||
            builtins.match "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$" cfg.reverse.uuid
            != null;
        message = "roles.xray.reverse.uuid must be a UUID when portal or bridge is enabled";
      }
      {
        assertion = !cfg.reverse.portal.enable || cfg.server.enable;
        message = "roles.xray.reverse.portal requires roles.xray.server.enable";
      }
      {
        assertion = !cfg.reverse.bridge.enable || cfg.server.enable;
        message = "roles.xray.reverse.bridge requires roles.xray.server.enable";
      }
      {
        assertion = !cfg.reverse.portal.enable || cfg.server.vlessXhttp.enable;
        message = "roles.xray.reverse.portal requires roles.xray.server.vlessXhttp.enable";
      }
      {
        assertion =
          !cfg.reverse.bridge.enable
          || (
            cfg.reverse.bridge.address != ""
            && cfg.reverse.bridge.serverName != ""
            && cfg.reverse.bridge.publicKey != ""
            && cfg.reverse.bridge.shortId != ""
            && cfg.reverse.bridge.path != ""
          );
        message = "roles.xray.reverse.bridge requires nonempty address, serverName, publicKey, shortId and path";
      }
    ];

    # SNI routing (server/relay mode only)
    roles.sni-router = mkIf cfg.server.enable {
      enable = true;
      entries = serverSniEntries ++ relaySniEntries ++ subsSniEntries;
    };

    # Eval-time view of the exact JSON handed to pkgs.writeText below.
    roles.xray._configTemplate = xrayConfigTemplate;

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
          # Hysteria credentials are passed as CREDENTIALS_DIRECTORY paths,
          # not contents: the jq stage assigns them to certificateFile/keyFile.
          # Paths are emitted only when the corresponding inbound is enabled on
          # this host, mirroring the LoadCredential list; absent assignments
          # stay inert because no hysteria inbound exists to consume them.
          hysteriaCredentialPaths =
            lib.optionalString hysteriaServerEnabled ''
              cert="$CREDENTIALS_DIRECTORY/hysteria-cert"
              certKey="$CREDENTIALS_DIRECTORY/hysteria-key"
            ''
            + lib.optionalString hysteriaRelayInboundEnabled ''
              relayCert="$CREDENTIALS_DIRECTORY/hysteria-relay-cert"
              relayKey="$CREDENTIALS_DIRECTORY/hysteria-relay-key"
            '';
        in
        ''
          set -euo pipefail
          umask 077
          configFile="$(mktemp)"

          privateKey="$(cat "$CREDENTIALS_DIRECTORY/private-key")"
          cert="" certKey="" relayCert="" relayKey=""
          ${hysteriaCredentialPaths}
          cat ${configTemplateFile} \
            | jq \
                --arg privateKey "$privateKey" \
                --arg cert "$cert" \
                --arg certKey "$certKey" \
                --arg relayCert "$relayCert" \
                --arg relayKey "$relayKey" \
                '.inbounds[] |=
                  if (.streamSettings.security // "") == "reality" then
                    .streamSettings.realitySettings.privateKey = $privateKey
                  elif .protocol != "hysteria" then .
                  elif .tag == "hy2-relay-in" then
                    .streamSettings.tlsSettings.certificates[0] = {certificateFile: $relayCert, keyFile: $relayKey}
                  else
                    .streamSettings.tlsSettings.certificates[0] = {certificateFile: $cert, keyFile: $certKey}
                  end' \
            > "$configFile"

          # Activation guard: refuse to launch an invalid rendered config.
          xray run -test -config "$configFile"
          exec xray -config "$configFile"
        '';
    };
  };
}
