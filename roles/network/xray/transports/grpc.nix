# roles/network/xray/transports/grpc.nix
#
# VLESS over gRPC.
{ lib, helpers }:

with lib;

rec {
  name = "vlessGrpc";
  tagPrefix = "vless-grpc";
  serverPort = 9001;
  relayPort = 9011;

  serverOptions = {
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

  clientOptions = {
    enable = mkEnableOption "VLESS over gRPC";
    server = mkOption {
      type = types.str;
      description = "Server domain or IP";
    };
    port = mkOption {
      type = types.port;
      default = 443;
      description = "Server port";
    };
    serverName = mkOption {
      type = types.str;
      default = "";
      description = "Reality SNI for this transport";
    };
    serviceName = mkOption {
      type = types.str;
      default = "VlGrpc";
      description = "gRPC service name (must match server)";
    };
    auth = {
      name = mkOption {
        type = types.str;
        default = "";
        description = "Username (informational)";
      };
      uuid = mkOption {
        type = types.str;
        description = "UUID for authentication";
      };
    };
  };

  relayInboundOptions = {
    sni = mkOption {
      type = types.str;
      description = "SNI for relay gRPC inbound (must differ from server's gRPC SNI)";
    };
  };

  relayTargetOptions = {
    enable = mkEnableOption "relay outbound VLESS over gRPC";
    serverName = mkOption {
      type = types.str;
      default = "";
      description = "Reality SNI for relay outbound gRPC";
    };
    serviceName = mkOption {
      type = types.str;
      default = "VlGrpc";
      description = "gRPC service name of the target server";
    };
  };

  subscriptionUpstreamOptions = {
    enable = mkEnableOption "advertise VLESS+gRPC in generated subscriptions";
    sni = mkOption {
      type = types.str;
      description = "Reality SNI for gRPC";
    };
    serviceName = mkOption {
      type = types.str;
      default = "VlGrpc";
      description = "gRPC service name clients must use";
    };
  };

  mkServerInbound =
    {
      cfg,
      clients,
      shortIds,
    }:
    {
      listen = "127.0.0.1";
      port = serverPort;
      protocol = "vless";
      tag = "vless-grpc-in";
      settings = {
        clients = clients.noFlow;
        decryption = "none";
      };
      streamSettings = {
        network = "grpc";
        security = "reality";
        realitySettings =
          (helpers.mkRealityServerSettings {
            inherit (cfg) sni;
            inherit shortIds;
          })
          // {
            alpn = [ "h2" ];
          };
        grpcSettings = {
          serviceName = cfg.serviceName;
        };
        sockopt.acceptProxyProtocol = true;
      };
    };

  mkRelayInbound =
    {
      cfg,
      serverCfg,
      clients,
      shortIds,
    }:
    {
      listen = "127.0.0.1";
      port = relayPort;
      protocol = "vless";
      tag = "vless-grpcFwd-in";
      settings = {
        clients = clients.noFlow;
        decryption = "none";
      };
      streamSettings = {
        network = "grpc";
        security = "reality";
        realitySettings =
          (helpers.mkRealityServerSettings {
            inherit (cfg) sni;
            inherit shortIds;
          })
          // {
            alpn = [ "h2" ];
          };
        grpcSettings = {
          serviceName = serverCfg.serviceName;
        };
        sockopt.acceptProxyProtocol = true;
      };
    };

  mkClientOutbound =
    { cfg, realityCfg }:
    helpers.mkVnextOutbound {
      tag = "vless-grpc-out";
      address = cfg.server;
      port = cfg.port;
      uuid = cfg.auth.uuid;
      streamSettings = {
        network = "grpc";
        security = "reality";
        realitySettings = helpers.mkRealityClientSettings {
          reality = realityCfg;
          serverName = cfg.serverName;
        };
        grpcSettings = {
          serviceName = cfg.serviceName;
        };
      };
    };

  mkRelayOutbound =
    {
      cfg,
      realityCfg,
      user,
      serverAddr,
    }:
    helpers.mkVnextOutbound {
      tag = "relay-grpc-out";
      address = serverAddr;
      port = 443;
      uuid = user.uuid;
      streamSettings = {
        network = "grpc";
        security = "reality";
        realitySettings = helpers.mkRealityClientSettings {
          reality = realityCfg;
          serverName = cfg.serverName;
        };
        grpcSettings = {
          serviceName = cfg.serviceName;
        };
      };
    };

  mkSubscriptionEntry =
    {
      serverAddr,
      uuid,
      fingerprint,
      realityPublicKey,
      shortId,
      cfg,
    }:
    helpers.mkVlessUri {
      inherit uuid;
      addr = serverAddr;
      port = 443;
      params = {
        encryption = "none";
        security = "reality";
        type = "grpc";
        serviceName = cfg.serviceName;
        sni = cfg.sni;
        pbk = realityPublicKey;
        sid = shortId;
        fp = fingerprint;
        alpn = "h2";
      };
      tag = "vless-grpc";
    };
}
