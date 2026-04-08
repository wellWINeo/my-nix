# roles/network/xray/transports/tcp.nix
#
# VLESS over direct TCP with Vision flow.
{ lib, helpers }:

with lib;

rec {
  name = "vlessTcp";
  tagPrefix = "vless-tcp";
  serverPort = 9000;
  relayPort = 9010;

  # --- Option schema fragments ---

  serverOptions = {
    enable = mkEnableOption "VLESS over direct TCP with Vision flow";
    sni = mkOption {
      type = types.str;
      default = "api.oneme.ru";
      description = "Reality SNI and camouflage target for TCP+Vision transport";
    };
  };

  clientOptions = {
    enable = mkEnableOption "VLESS over direct TCP with Vision flow";
    server = mkOption { type = types.str; description = "Server domain or IP"; };
    port = mkOption { type = types.port; default = 443; description = "Server port"; };
    serverName = mkOption {
      type = types.str;
      default = "";
      description = "Reality SNI for this transport (overrides shared reality.serverName)";
    };
    auth = {
      name = mkOption { type = types.str; default = ""; description = "Username (informational)"; };
      uuid = mkOption { type = types.str; description = "UUID for authentication"; };
    };
  };

  relayInboundOptions = {
    sni = mkOption {
      type = types.str;
      description = "SNI for relay TCP inbound (must differ from server's TCP SNI)";
    };
  };

  relayTargetOptions = {
    enable = mkEnableOption "relay outbound VLESS over direct TCP with Vision flow";
    serverName = mkOption {
      type = types.str;
      default = "";
      description = "Reality SNI for relay outbound TCP (overrides target.reality.serverName)";
    };
  };

  subscriptionUpstreamOptions = {
    enable = mkEnableOption "advertise VLESS+TCP+Vision in generated subscriptions";
    sni = mkOption {
      type = types.str;
      description = "Reality SNI clients will use for TCP+Vision connections";
    };
  };

  # --- Builders ---

  mkServerInbound =
    { cfg, clients, shortIds }:
    {
      listen = "127.0.0.1";
      port = serverPort;
      protocol = "vless";
      tag = "vless-tcp-in";
      settings = {
        clients = clients.withFlow;
        decryption = "none";
      };
      streamSettings = {
        network = "tcp";
        security = "reality";
        realitySettings = helpers.mkRealityServerSettings { inherit (cfg) sni; inherit shortIds; };
        sockopt.acceptProxyProtocol = true;
      };
    };

  mkRelayInbound =
    { cfg, serverCfg, clients, shortIds }:
    {
      listen = "127.0.0.1";
      port = relayPort;
      protocol = "vless";
      tag = "vless-tcp-fwd-in";
      settings = {
        clients = clients.withFlow;
        decryption = "none";
      };
      streamSettings = {
        network = "tcp";
        security = "reality";
        realitySettings = helpers.mkRealityServerSettings { inherit (cfg) sni; inherit shortIds; };
        sockopt.acceptProxyProtocol = true;
      };
    };

  mkClientOutbound =
    { cfg, realityCfg }:
    helpers.mkVnextOutbound {
      tag = "vless-tcp-out";
      address = cfg.server;
      port = cfg.port;
      uuid = cfg.auth.uuid;
      extraUser = { flow = "xtls-rprx-vision"; };
      streamSettings = {
        network = "tcp";
        security = "reality";
        realitySettings = helpers.mkRealityClientSettings {
          reality = realityCfg;
          serverName = cfg.serverName;
        };
      };
    };

  mkRelayOutbound =
    { cfg, realityCfg, user, serverAddr }:
    helpers.mkVnextOutbound {
      tag = "relay-tcp-out";
      address = serverAddr;
      port = 443;
      uuid = user.uuid;
      extraUser = { flow = "xtls-rprx-vision"; };
      streamSettings = {
        network = "tcp";
        security = "reality";
        realitySettings = helpers.mkRealityClientSettings {
          reality = realityCfg;
          serverName = cfg.serverName;
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
        type = "tcp";
        flow = "xtls-rprx-vision";
        sni = cfg.sni;
        pbk = realityPublicKey;
        sid = shortId;
        fp = fingerprint;
      };
      tag = "vless-tcp";
    };
}
