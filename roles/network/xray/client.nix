# roles/network/xray/client.nix
#
# Defines roles.xray.client options. Runs its own xray process (independent
# from server/relay). Built by folding over the transport registry.
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.roles.xray.client;
  transports = import ./transports { inherit lib; };
  transportList = lib.attrValues transports;

  enabledTransports = lib.filter (t: cfg.${t.name}.enable) transportList;

  realityCfg = cfg.reality;

  xrayConfig = {
    log = { loglevel = "info"; };

    inbounds = [
      {
        listen = "0.0.0.0";
        port = cfg.port;
        protocol = "socks";
        tag = "socks-in";
        settings = {
          auth = "noauth";
          udp = true;
        };
      }
    ];

    outbounds =
      (map (t: t.mkClientOutbound {
        cfg = cfg.${t.name};
        inherit realityCfg;
      }) enabledTransports)
      ++ [
        {
          protocol = "freedom";
          tag = "direct-out";
        }
      ];

    routing = {
      rules = [
        {
          type = "field";
          inboundTag = [ "socks-in" ];
          balancerTag = "proxy-balancer";
        }
      ];
      balancers = [
        {
          tag = "proxy-balancer";
          selector = map (t: "${t.tagPrefix}-out") enabledTransports;
          strategy = { type = "random"; };
        }
      ];
    };
  };
in
{
  options.roles.xray.client = {
    enable = mkEnableOption "xray proxy client";

    port = mkOption {
      type = types.port;
      default = 1081;
      description = "SOCKS5 listen port";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open firewall for SOCKS port";
    };

    reality = {
      enable = mkEnableOption "Reality TLS";
      publicKey = mkOption { type = types.str; default = ""; description = "Server's Reality public key"; };
      shortId = mkOption { type = types.str; default = ""; description = "Authorized shortId"; };
      serverName = mkOption { type = types.str; default = ""; description = "Fallback SNI"; };
      fingerprint = mkOption { type = types.str; default = "chrome"; description = "uTLS fingerprint"; };
    };
  } // lib.mapAttrs (_: t: t.clientOptions) transports;

  config = mkIf (config.roles.xray.enable && cfg.enable) {
    assertions = [
      {
        assertion = lib.any (t: cfg.${t.name}.enable) transportList;
        message = "At least one xray client outbound must be enabled";
      }
      {
        assertion =
          !cfg.reality.enable
          || (
            cfg.reality.publicKey != ""
            && cfg.reality.shortId != ""
            && cfg.reality.serverName != ""
            && cfg.reality.fingerprint != ""
          );
        message = "roles.xray.client.reality.{publicKey,shortId,serverName,fingerprint} must be set when reality.enable = true";
      }
    ];

    services.xray = {
      enable = true;
      settings = xrayConfig;
    };

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ];
    networking.firewall.allowedUDPPorts = mkIf cfg.openFirewall [ cfg.port ];
  };
}
