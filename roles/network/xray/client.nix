# roles/network/xray/client.nix
#
# Defines roles.xray.client options. Runs its own xray process (independent
# from server/relay) through the upstream services.xray module. Local
# listeners (SOCKS/HTTP/tunnels) live under .ingress, the single VLESS+REALITY
# server link and its RAW/gRPC/xHTTP candidates under .egress.
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.roles.xray.client;
  vless = import ./vless.nix { inherit lib; };

  ingressCfg = cfg.ingress;
  egressCfg = cfg.egress;
  realityCfg = egressCfg.reality;

  fragmentClientHelloOutbound =
    outbound:
    if config.roles.xray.fragmentClientHello then
      vless.withClientHelloFragmentation outbound
    else
      outbound;

  backupEnabled = egressCfg.backupPort != null;

  # Balancer selector tag of a transport's backup client outbound; must match
  # the primary tag convention ("<tag>-out").
  backupOutboundTag = t: "${t.tag}-backup-out";

  # Client-side REALITY streamSettings shared by every transport. serverName
  # is the per-transport SNI; the egress schema has no shared fallback SNI.
  realityClientSettings = serverName: {
    publicKey = realityCfg.publicKey;
    shortId = realityCfg.shortId;
    inherit serverName;
    fingerprint = realityCfg.fingerprint;
  };

  # The three VLESS transports, written out explicitly (no shared transport
  # registry): RAW is VLESS over TCP with the Vision flow, gRPC and xHTTP use
  # no flow. The attrset + attrValues keeps alphabetical evaluation order,
  # reproducing the outbound order the previous transport registry emitted.
  transports = {
    grpc = {
      cfg = egressCfg.vless.grpc;
      tag = "vless-grpc";
      flow = null;
      streamSettings = {
        network = "grpc";
        security = "reality";
        realitySettings = realityClientSettings egressCfg.vless.grpc.serverName;
        grpcSettings.serviceName = egressCfg.vless.grpc.serviceName;
      };
    };
    raw = {
      cfg = egressCfg.vless.raw;
      tag = "vless-tcp";
      flow = "xtls-rprx-vision";
      streamSettings = {
        network = "tcp";
        security = "reality";
        realitySettings = realityClientSettings egressCfg.vless.raw.serverName;
      };
    };
    xhttp = {
      cfg = egressCfg.vless.xhttp;
      tag = "vless-xhttp";
      flow = null;
      streamSettings = {
        network = "xhttp";
        security = "reality";
        realitySettings = realityClientSettings egressCfg.vless.xhttp.serverName;
        xhttpSettings.path = egressCfg.vless.xhttp.path;
      };
    };
  };

  transportList = lib.attrValues transports;
  enabledTransports = lib.filter (t: t.cfg.enable) transportList;

  mkTransportOutbound =
    t:
    { tag, port }:
    vless.mkRegularOutbound {
      inherit tag port;
      address = egressCfg.server;
      uuid = egressCfg.user.uuid;
      flow = t.flow;
      streamSettings = t.streamSettings;
    };

  parseEndpoint =
    optionName: endpoint:
    let
      matches = builtins.match "^(.+):([0-9]+)$" endpoint;
    in
    if matches == null then
      throw "roles.xray.client.ingress.${optionName} must be ADDRESS:PORT"
    else
      let
        rawAddress = elemAt matches 0;
        port = toInt (elemAt matches 1);
        hasOpeningBracket = hasPrefix "[" rawAddress;
        hasClosingBracket = hasSuffix "]" rawAddress;
        address = if hasOpeningBracket then removePrefix "[" (removeSuffix "]" rawAddress) else rawAddress;
      in
      if hasOpeningBracket != hasClosingBracket || address == "" then
        throw "roles.xray.client.ingress.${optionName} must have a non-empty address with paired IPv6 brackets"
      else if port < 1 || port > 65535 then
        throw "roles.xray.client.ingress.${optionName} port must be in the range 1..65535"
      else
        { inherit address port; };

  parsedTunnels = imap0 (index: tunnel: {
    inherit index;
    listen = parseEndpoint "tunnels[${toString index}].listen" tunnel.listen;
    target = parseEndpoint "tunnels[${toString index}].target" tunnel.target;
  }) ingressCfg.tunnels;

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
  ++ optional ingressCfg.http.enable "http-in"
  ++ map (tunnel: "tunnel-${toString tunnel.index}-in") parsedTunnels;

  xrayConfig = {
    log = {
      loglevel = "info";
    };

    inbounds = [
      {
        listen = "0.0.0.0";
        port = ingressCfg.socks.port;
        protocol = "socks";
        tag = "socks-in";
        settings = {
          auth = "noauth";
          udp = true;
        };
      }
    ]
    ++ lib.optionals ingressCfg.http.enable [
      {
        listen = "0.0.0.0";
        port = ingressCfg.http.port;
        protocol = "http";
        tag = "http-in";
        settings = { };
      }
    ]
    ++ tunnelInbounds;

    outbounds =
      (map fragmentClientHelloOutbound (
        lib.concatMap (
          t:
          [
            # Primary candidate (per-transport port, TCP/443 by default).
            (mkTransportOutbound t {
              tag = "${t.tag}-out";
              port = t.cfg.port;
            })
          ]
          ++ lib.optionals backupEnabled [
            # Backup candidate on backupPort (e.g. TCP/2053).
            (mkTransportOutbound t {
              tag = backupOutboundTag t;
              port = egressCfg.backupPort;
            })
          ]
        ) enabledTransports
      ))
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
          selector =
            (map (t: "${t.tag}-out") enabledTransports)
            ++ lib.optionals backupEnabled (map backupOutboundTag enabledTransports);
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

    ingress = {
      socks.port = mkOption {
        type = types.port;
        default = 1081;
        description = "SOCKS5 listen port";
      };

      http = {
        enable = mkEnableOption "HTTP proxy inbound";

        port = mkOption {
          type = types.port;
          default = 3128;
          description = "HTTP proxy listen port";
        };
      };

      openFirewall = mkOption {
        type = types.bool;
        default = true;
        description = "Open firewall for the SOCKS and HTTP proxy listen ports";
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
    };

    egress = {
      server = mkOption {
        type = types.str;
        description = "Server domain or IP";
      };

      user = mkOption {
        type = types.attrs;
        description = "Proxy user entry; must have at least { name, uuid }";
      };

      backupPort = mkOption {
        type = types.nullOr types.port;
        default = null;
        description = "Optional backup server port; when set, every enabled VLESS transport gets a second outbound candidate on it";
      };

      reality = {
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
        fingerprint = mkOption {
          type = types.str;
          default = "chrome";
          description = "uTLS fingerprint";
        };
      };

      vless = {
        raw = {
          enable = mkEnableOption "VLESS over direct TCP with Vision flow";
          port = mkOption {
            type = types.port;
            default = 443;
            description = "Server port";
          };
          serverName = mkOption {
            type = types.str;
            default = "";
            description = "Reality SNI";
          };
        };

        grpc = {
          enable = mkEnableOption "VLESS over gRPC";
          port = mkOption {
            type = types.port;
            default = 443;
            description = "Server port";
          };
          serverName = mkOption {
            type = types.str;
            default = "";
            description = "Reality SNI";
          };
          serviceName = mkOption {
            type = types.str;
            default = "VlGrpc";
            description = "gRPC serviceName";
          };
        };

        xhttp = {
          enable = mkEnableOption "VLESS over xHTTP";
          port = mkOption {
            type = types.port;
            default = 443;
            description = "Server port";
          };
          serverName = mkOption {
            type = types.str;
            default = "";
            description = "Reality SNI";
          };
          path = mkOption {
            type = types.str;
            default = "/vl-xhttp";
            description = "xHTTP path";
          };
        };
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.any (t: t.cfg.enable) transportList;
        message = "At least one xray client outbound must be enabled";
      }
      {
        assertion = egressCfg.user ? uuid && egressCfg.user.uuid != "";
        message = "roles.xray.client.egress.user must have a nonempty uuid";
      }
      {
        assertion = realityCfg.publicKey != "" && realityCfg.shortId != "" && realityCfg.fingerprint != "";
        message = "roles.xray.client.egress.reality.{publicKey,shortId,fingerprint} must be set";
      }
      {
        assertion = all (t: t.cfg.serverName != "") enabledTransports;
        message = "every enabled roles.xray.client.egress.vless.*.serverName must be set";
      }
      {
        assertion = !ingressCfg.http.enable || ingressCfg.http.port != ingressCfg.socks.port;
        message = "roles.xray.client.ingress.http.port must differ from roles.xray.client.ingress.socks.port";
      }
      {
        assertion = length (unique (map (tunnel: tunnel.listen) parsedTunnels)) == length parsedTunnels;
        message = "roles.xray.client.ingress.tunnels must not contain duplicate listen endpoints";
      }
      {
        assertion = all (
          tunnel:
          tunnel.listen.port != ingressCfg.socks.port
          && (!ingressCfg.http.enable || tunnel.listen.port != ingressCfg.http.port)
        ) parsedTunnels;
        message = "roles.xray.client.ingress.tunnels must not reuse the SOCKS or HTTP proxy listen port";
      }
      {
        assertion =
          egressCfg.backupPort == null || all (t: t.cfg.port != egressCfg.backupPort) enabledTransports;
        message = "roles.xray.client.egress.backupPort must differ from every enabled transport's primary server port";
      }
    ];

    services.xray = {
      enable = true;
      settings = xrayConfig;
    };

    networking.firewall.allowedTCPPorts = mkIf ingressCfg.openFirewall (
      [ ingressCfg.socks.port ] ++ lib.optional ingressCfg.http.enable ingressCfg.http.port
    );
    networking.firewall.allowedUDPPorts = mkIf ingressCfg.openFirewall [ ingressCfg.socks.port ];
  };
}
