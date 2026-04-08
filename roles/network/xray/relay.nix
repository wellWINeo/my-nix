# roles/network/xray/relay.nix
#
# Defines roles.xray.relay options and exports _relayConfig fragment.
# Relay inbounds are gated on the server's corresponding transport being
# enabled (to reuse server's serviceName/path/shortIds). Relay outbounds
# are gated independently via cfg.target.<transport>.enable.
{
  config,
  lib,
  ...
}:

with lib;

let
  cfg = config.roles.xray.relay;
  serverCfg = config.roles.xray.server;
  secrets = import ../../../secrets;
  transports = import ./transports { inherit lib; };
  transportList = lib.attrValues transports;

  shortIds = secrets.xray.reality.shortIds or [ ];

  clients = {
    withFlow = map (u: {
      id = u.uuid;
      flow = "xtls-rprx-vision";
      email = "${u.name}@xray";
    }) secrets.singBoxUsers;

    noFlow = map (u: {
      id = u.uuid;
      email = "${u.name}@xray";
    }) secrets.singBoxUsers;
  };

  enabledInbound = lib.filter (t: serverCfg.${t.name}.enable) transportList;
  enabledOutbound = lib.filter (t: cfg.target.${t.name}.enable) transportList;

  relayConfig = {
    inbounds = map (t: t.mkRelayInbound {
      cfg = cfg.${t.name};
      serverCfg = serverCfg.${t.name};
      inherit clients shortIds;
    }) enabledInbound;

    outbounds = map (t: t.mkRelayOutbound {
      cfg = cfg.target.${t.name};
      targetCfg = cfg.target;
      realityCfg = cfg.target.reality;
      user = cfg.user;
      serverAddr = cfg.target.server;
    }) enabledOutbound;

    routing = {
      rules = lib.optionals (enabledInbound != [ ]) [
        {
          type = "field";
          inboundTag = map (t:
            if t.name == "vlessGrpc" then "vless-grpcFwd-in"
            else "${t.tagPrefix}-fwd-in"
          ) enabledInbound;
          balancerTag = "relay-balancer";
        }
      ];
      balancers = lib.optionals (enabledOutbound != [ ]) [
        {
          tag = "relay-balancer";
          selector = map (t: "relay-${lib.removePrefix "vless-" t.tagPrefix}-out") enabledOutbound;
          strategy = { type = "leastPing"; };
        }
      ];
    };

    nginxSniEntries = map (t: {
      sni = cfg.${t.name}.sni;
      port = t.relayPort;
    }) enabledInbound;
  };
in
{
  options.roles.xray.relay = {
    enable = mkEnableOption "relay traffic to another xray server";

    user = mkOption {
      type = types.attrs;
      description = "User credentials for authenticating to the target server ({ uuid, name, ... } from secrets.singBoxUsers)";
    };

    target = {
      server = mkOption {
        type = types.str;
        description = "Target xray server IP or hostname";
      };

      reality = {
        publicKey = mkOption { type = types.str; default = ""; description = "Target server's Reality public key"; };
        shortId = mkOption { type = types.str; default = ""; description = "Authorized shortId"; };
        serverName = mkOption { type = types.str; default = ""; description = "Fallback SNI"; };
        fingerprint = mkOption { type = types.str; default = "chrome"; description = "uTLS fingerprint"; };
      };
    } // lib.mapAttrs (_: t: t.relayTargetOptions) transports;
  } // lib.mapAttrs (_: t: t.relayInboundOptions) transports;

  config = mkIf (config.roles.xray.enable && cfg.enable) {
    assertions = [
      {
        assertion = config.roles.xray.server.enable;
        message = "roles.xray.relay requires roles.xray.server to be enabled";
      }
      {
        assertion = enabledOutbound != [ ];
        message = "At least one relay target transport must be enabled (roles.xray.relay.target.<transport>.enable)";
      }
      {
        assertion = enabledInbound != [ ];
        message = "At least one server transport must be enabled for relay inbounds";
      }
    ];

    roles.xray._relayConfig = relayConfig;
  };
}
