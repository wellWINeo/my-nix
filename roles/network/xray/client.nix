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

  parseEndpoint =
    optionName: endpoint:
    let
      matches = builtins.match "^(.+):([0-9]+)$" endpoint;
    in
    if matches == null then
      throw "roles.xray.client.${optionName} must be ADDRESS:PORT"
    else
      let
        rawAddress = elemAt matches 0;
        port = toInt (elemAt matches 1);
        hasOpeningBracket = hasPrefix "[" rawAddress;
        hasClosingBracket = hasSuffix "]" rawAddress;
        address = if hasOpeningBracket then removePrefix "[" (removeSuffix "]" rawAddress) else rawAddress;
      in
      if hasOpeningBracket != hasClosingBracket || address == "" then
        throw "roles.xray.client.${optionName} must have a non-empty address with paired IPv6 brackets"
      else if port < 1 || port > 65535 then
        throw "roles.xray.client.${optionName} port must be in the range 1..65535"
      else
        { inherit address port; };

  parsedTunnels = imap0 (index: tunnel: {
    inherit index;
    listen = parseEndpoint "tunnels[${toString index}].listen" tunnel.listen;
    target = parseEndpoint "tunnels[${toString index}].target" tunnel.target;
  }) cfg.tunnels;

  tunnelInbounds = map (tunnel: {
    listen = tunnel.listen.address;
    port = tunnel.listen.port;
    protocol = "tunnel";
    tag = "tunnel-${toString tunnel.index}-in";
    settings = {
      allowedNetwork = "tcp";
      rewriteAddress = tunnel.target.address;
      rewritePort = tunnel.target.port;
      followRedirect = false;
    };
  }) parsedTunnels;

  proxyInboundTags = [
    "socks-in"
  ]
  ++ optional cfg.http.enable "http-in"
  ++ map (tunnel: "tunnel-${toString tunnel.index}-in") parsedTunnels;

  xrayConfig = {
    log = {
      loglevel = "info";
    };

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
    ]
    ++ lib.optionals cfg.http.enable [
      {
        listen = "0.0.0.0";
        port = cfg.http.port;
        protocol = "http";
        tag = "http-in";
        settings = { };
      }
    ]
    ++ tunnelInbounds;

    outbounds =
      (map (
        t:
        t.mkClientOutbound {
          cfg = cfg.${t.name};
          inherit realityCfg;
        }
      ) enabledTransports)
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
          inboundTag = proxyInboundTags;
          balancerTag = "proxy-balancer";
        }
      ];
      balancers = [
        {
          tag = "proxy-balancer";
          selector = map (t: "${t.tagPrefix}-out") enabledTransports;
          strategy = {
            type = "leastPing";
          };
        }
      ];
    };

    observatory = {
      subjectSelector = [ "vless-" ];
      probeURL = "https://www.google.com/generate_204";
      probeInterval = "60s";
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
      publicKey = mkOption {
        type = types.str;
        default = "";
        description = "Server's Reality public key";
      };
      shortId = mkOption {
        type = types.str;
        default = "";
        description = "Authorized shortId";
      };
      serverName = mkOption {
        type = types.str;
        default = "";
        description = "Fallback SNI";
      };
      fingerprint = mkOption {
        type = types.str;
        default = "chrome";
        description = "uTLS fingerprint";
      };
    };

    tunnels = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            listen = mkOption {
              type = types.str;
              example = "127.0.0.1:5053";
              description = "Local address and TCP port for the Xray tunnel listener";
            };
            target = mkOption {
              type = types.str;
              example = "1.1.1.1:853";
              description = "Fixed remote address and TCP port carried through Xray";
            };
          };
        }
      );
      default = [ ];
      description = "Fixed-destination TCP tunnels routed through the Xray proxy balancer";
    };

    http = {
      enable = mkEnableOption "HTTP proxy inbound";

      port = mkOption {
        type = types.port;
        default = 3128;
        description = "HTTP proxy listen port";
      };
    };
  }
  // lib.mapAttrs (_: t: t.clientOptions) transports;

  config = mkIf (config.roles.xray.enable && cfg.enable) {
    assertions = [
      {
        assertion = lib.any (t: cfg.${t.name}.enable) transportList;
        message = "At least one xray client outbound must be enabled";
      }
      {
        assertion = !cfg.http.enable || cfg.http.port != cfg.port;
        message = "roles.xray.client.http.port must differ from roles.xray.client.port";
      }
      {
        assertion = length (unique (map (tunnel: tunnel.listen) parsedTunnels)) == length parsedTunnels;
        message = "roles.xray.client.tunnels must not contain duplicate listen endpoints";
      }
      {
        assertion = all (
          tunnel: tunnel.listen.port != cfg.port && (!cfg.http.enable || tunnel.listen.port != cfg.http.port)
        ) parsedTunnels;
        message = "roles.xray.client.tunnels must not reuse the SOCKS or HTTP proxy listen port";
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

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall (
      [ cfg.port ] ++ lib.optional cfg.http.enable cfg.http.port
    );
    networking.firewall.allowedUDPPorts = mkIf cfg.openFirewall [ cfg.port ];
  };
}
