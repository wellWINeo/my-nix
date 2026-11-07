# roles/network/xray/server.nix
#
# Defines roles.xray.server: the complete public server mode (Buyan-style).
# Public clients enter through ingress (VLESS RAW/gRPC/xHTTP on the
# SNI-routed TCP/443 backends plus an optional Hysteria2 UDP server inbound)
# and leave through direct-out. The optional reverseBridge adds two
# Buyan-initiated reverse links per relay portal: simplified VLESS outbounds
# paired with host-qualified logical inbound tags, whose traffic is restricted
# to the reverse-public-out freedom outbound
# (public TCP/UDP only).
{
  config,
  lib,
  ...
}:

with lib;

let
  cfg = config.roles.xray.server;
  vless = import ./vless.nix { inherit lib; };
  hysteria = import ./hysteria.nix { inherit lib; };

  ingressCfg = cfg.ingress;
  bridgeCfg = cfg.reverseBridge;
  bridgeEnabled = bridgeCfg.enable;

  uuidFormat =
    uuid:
    builtins.match "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$" uuid
    != null;

  vlessClients = {
    raw = map (u: {
      id = u.uuid;
      flow = "xtls-rprx-vision";
      email = "${u.name}@xray";
    }) ingressCfg.users;
    plain = map (u: {
      id = u.uuid;
      email = "${u.name}@xray";
    }) ingressCfg.users;
  };

  ingressTransports = {
    grpc = {
      enable = ingressCfg.vless.grpc.enable;
      sni = ingressCfg.vless.grpc.sni;
      inbound = vless.mkInbound {
        transport = "grpc";
        tag = "vless-grpc-in";
        port = 9001;
        clients = vlessClients.plain;
        sni = ingressCfg.vless.grpc.sni;
        shortIds = ingressCfg.reality.shortIds;
        serviceName = ingressCfg.vless.grpc.serviceName;
      };
    };
    raw = {
      enable = ingressCfg.vless.raw.enable;
      sni = ingressCfg.vless.raw.sni;
      inbound = vless.mkInbound {
        transport = "raw";
        tag = "vless-raw-in";
        port = 9000;
        clients = vlessClients.raw;
        sni = ingressCfg.vless.raw.sni;
        shortIds = ingressCfg.reality.shortIds;
      };
    };
    xhttp = {
      enable = ingressCfg.vless.xhttp.enable;
      sni = ingressCfg.vless.xhttp.sni;
      inbound = vless.mkInbound {
        transport = "xhttp";
        tag = "vless-xhttp-in";
        port = 9002;
        clients = vlessClients.plain;
        sni = ingressCfg.vless.xhttp.sni;
        shortIds = ingressCfg.reality.shortIds;
        path = ingressCfg.vless.xhttp.path;
      };
    };
  };
  enabledIngress = filter (t: t.enable) (attrValues ingressTransports);
  hyEnabled = ingressCfg.hysteria2.enable;
  publicIngressTags =
    (map (t: t.inbound.tag) enabledIngress) ++ optional hyEnabled hysteria.serverInboundTag;

  # Dedicated restricted egress for traffic arriving over the reverse links:
  # public TCP/UDP only; everything else stays blocked.
  reversePublicOutbound = {
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

  bridgeOutbound =
    address: tag: inboundTag: flow: streamSettings:
    let
      outbound = vless.mkReverseOutbound {
        tag = tag;
        inherit address;
        port = 443;
        uuid = bridgeCfg.user.uuid;
        inboundTag = inboundTag;
        flow = flow;
        streamSettings = streamSettings;
      };
    in
    if config.roles.xray.fragmentClientHello then
      vless.withClientHelloFragmentation outbound
    else
      outbound;

  bridgeRawOutbound =
    address: tag: inboundTag:
    bridgeOutbound address tag inboundTag "xtls-rprx-vision" {
      network = "tcp";
      security = "reality";
      realitySettings = {
        publicKey = bridgeCfg.reality.publicKey;
        shortId = bridgeCfg.reality.shortId;
        serverName = bridgeCfg.vless.raw.serverName;
        fingerprint = "firefox";
      };
    };

  bridgeXhttpOutbound =
    address: tag: inboundTag:
    bridgeOutbound address tag inboundTag null {
      network = "xhttp";
      security = "reality";
      realitySettings = {
        publicKey = bridgeCfg.reality.publicKey;
        shortId = bridgeCfg.reality.shortId;
        serverName = bridgeCfg.vless.xhttp.serverName;
        fingerprint = "firefox";
      };
      xhttpSettings.path = bridgeCfg.vless.xhttp.path;
    };

  serverConfig = {
    log = {
      loglevel = "info";
    };
    inbounds =
      (map (t: t.inbound) enabledIngress)
      ++ optional hyEnabled (
        hysteria.mkServerInbound {
          cfg = ingressCfg.hysteria2;
          inherit (ingressCfg) users;
        }
      );
    outbounds = [
      {
        protocol = "blackhole";
        tag = "blocked-out";
      }
      {
        protocol = "freedom";
        tag = "direct-out";
      }
    ]
    ++ optionals bridgeEnabled (
      concatMap (relay: [
        (bridgeRawOutbound relay.address "bridge-${relay.host}-raw-out" "reverse-${relay.host}-raw-in")
        (bridgeXhttpOutbound relay.address "bridge-${relay.host}-xhttp-out"
          "reverse-${relay.host}-xhttp-in"
        )
      ]) bridgeCfg.addresses
      ++ [ reversePublicOutbound ]
    );
    routing.rules = [
      {
        type = "field";
        inboundTag = publicIngressTags;
        outboundTag = "direct-out";
      }
    ]
    ++ optionals bridgeEnabled (
      concatMap (relay: [
        {
          type = "field";
          inboundTag = [ "reverse-${relay.host}-raw-in" ];
          outboundTag = "reverse-public-out";
        }
        {
          type = "field";
          inboundTag = [ "reverse-${relay.host}-xhttp-in" ];
          outboundTag = "reverse-public-out";
        }
      ]) bridgeCfg.addresses
    );
  };
in
{
  options.roles.xray.server = {
    enable = mkEnableOption "xray public proxy server with REALITY (Buyan-style)";

    ingress = {
      users = mkOption {
        type = types.listOf types.attrs;
        default = [ ];
        description = "Proxy users to allow. Each entry must have at least { name, uuid }.";
      };

      reality = {
        privateKeyFile = mkOption {
          type = types.path;
          description = "Path to the REALITY private key file (injected at runtime via LoadCredential, not stored in the template)";
          example = "/etc/nixos/secrets/xray-reality-private-key";
        };
        shortIds = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Authorized REALITY short IDs for server inbounds";
        };
      };

      vless = {
        raw = {
          enable = mkEnableOption "VLESS RAW (TCP+Vision) server inbound";
          sni = mkOption {
            type = types.str;
            default = "";
            description = "REALITY SNI and camouflage target of the RAW server inbound";
          };
        };
        grpc = {
          enable = mkEnableOption "VLESS gRPC server inbound";
          sni = mkOption {
            type = types.str;
            default = "";
            description = "REALITY SNI and camouflage target of the gRPC server inbound";
          };
          serviceName = mkOption {
            type = types.str;
            default = "VlGrpc";
            description = "gRPC serviceName of the server inbound";
          };
        };
        xhttp = {
          enable = mkEnableOption "VLESS xHTTP server inbound";
          sni = mkOption {
            type = types.str;
            default = "";
            description = "REALITY SNI and camouflage target of the xHTTP server inbound";
          };
          path = mkOption {
            type = types.str;
            default = "/vl-xhttp";
            description = "xHTTP path of the server inbound";
          };
        };
      };

      hysteria2 = hysteria.serverOptions.hysteria;
    };

    reverseBridge = {
      enable = mkEnableOption "Buyan-initiated reverse bridge to a relay portal";

      user = mkOption {
        type = types.nullOr types.attrs;
        default = null;
        description = "Relay-authorized user entry ({ name, uuid, ... }) used by both bridge outbounds; passed explicitly by the machine config";
      };

      addresses = mkOption {
        type = types.listOf (
          types.submodule {
            options = {
              host = mkOption {
                type = types.str;
                description = "Relay name used in bridge tags";
              };
              address = mkOption {
                type = types.str;
                description = "Relay address the bridge dials";
              };
            };
          }
        );
        default = [ ];
        description = "Named relays using the same bridge identity and transport settings";
      };

      reality = {
        publicKey = mkOption {
          type = types.str;
          default = "";
          description = "Relay REALITY public key authenticating the bridge links";
        };
        shortId = mkOption {
          type = types.str;
          default = "";
          description = "Authorized REALITY short ID for the bridge links";
        };
      };

      vless = {
        raw.serverName = mkOption {
          type = types.str;
          default = "";
          description = "REALITY SNI of the relay RAW portal inbound (must match the relay ingress SNI)";
        };
        xhttp = {
          serverName = mkOption {
            type = types.str;
            default = "";
            description = "REALITY SNI of the relay xHTTP portal inbound (must match the relay ingress SNI)";
          };
          path = mkOption {
            type = types.str;
            default = "/vl-xhttp";
            description = "xHTTP path of the relay xHTTP portal inbound";
          };
        };
      };
    };

    _configTemplate = mkOption {
      type = types.attrs;
      internal = true;
      default = { };
      description = "The complete server-mode config template JSON produced by this module";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = enabledIngress != [ ] || hyEnabled;
        message = "roles.xray.server requires at least one enabled ingress transport (vless raw/grpc/xhttp or hysteria2)";
      }
      {
        assertion = all (t: !t.enable || t.sni != "") (attrValues ingressTransports);
        message = "every enabled roles.xray.server.ingress.vless.*.sni must be set";
      }
      {
        assertion = !ingressCfg.vless.grpc.enable || !(hasPrefix "/" ingressCfg.vless.grpc.serviceName);
        message = "roles.xray.server.ingress.vless.grpc.serviceName must not start with '/'";
      }
      {
        # certFile/keyFile are types.path with no default, so an unset value
        # already fails at module-evaluation time before this assertion runs;
        # the != null check here is a defensive guard, not the primary check.
        assertion =
          !hyEnabled || (ingressCfg.hysteria2.certFile != null && ingressCfg.hysteria2.keyFile != null);
        message = "roles.xray.server.ingress.hysteria2 requires certFile and keyFile";
      }
      {
        assertion = !hyEnabled || any (u: u.password != null && u.password != "") ingressCfg.users;
        message = "roles.xray.server.ingress.hysteria2 requires at least one user with a non-empty password";
      }
      {
        assertion =
          !bridgeEnabled
          || (
            bridgeCfg.user != null
            && bridgeCfg.user ? uuid
            && bridgeCfg.user.uuid != ""
            && uuidFormat bridgeCfg.user.uuid
            && bridgeCfg.reality.publicKey != ""
            && bridgeCfg.reality.shortId != ""
            && bridgeCfg.vless.raw.serverName != ""
            && bridgeCfg.vless.xhttp.serverName != ""
            && bridgeCfg.vless.xhttp.path != ""
          );
        message = "roles.xray.server.reverseBridge requires a user with a valid UUID and nonempty reality.publicKey, reality.shortId, vless.raw.serverName, vless.xhttp.serverName and vless.xhttp.path";
      }
      {
        assertion =
          !bridgeEnabled
          || (
            bridgeCfg.addresses != [ ]
            && all (
              relay: builtins.match "[a-zA-Z0-9_-]+" relay.host != null && relay.address != ""
            ) bridgeCfg.addresses
            && length (unique (map (relay: relay.host) bridgeCfg.addresses)) == length bridgeCfg.addresses
            && length (unique (map (relay: relay.address) bridgeCfg.addresses)) == length bridgeCfg.addresses
          );
        message = "roles.xray.server.reverseBridge.addresses requires unique valid host names and unique nonempty addresses";
      }
    ];

    networking.firewall.allowedUDPPorts = optional hyEnabled ingressCfg.hysteria2.port;

    roles.xray.server._configTemplate = serverConfig;
  };
}
