# roles/network/xray/transports/xhttp.nix
#
# VLESS over xHTTP.
{ lib, helpers }:

with lib;

rec {
  name = "vlessXhttp";
  tagPrefix = "vless-xhttp";
  serverPort = 9002;
  relayPort = 9012;

  serverOptions = {
    enable = mkEnableOption "VLESS over xHTTP";
    sni = mkOption {
      type = types.str;
      default = "onlymir.ru";
      description = "Reality SNI and camouflage target for xHTTP transport";
    };
    path = mkOption {
      type = types.str;
      default = "/vl-xhttp";
      description = "xHTTP path";
    };
  };

  clientOptions = {
    enable = mkEnableOption "VLESS over xHTTP";
    server = mkOption { type = types.str; description = "Server domain or IP"; };
    port = mkOption { type = types.port; default = 443; description = "Server port"; };
    serverName = mkOption {
      type = types.str;
      default = "";
      description = "Reality SNI for this transport";
    };
    path = mkOption {
      type = types.str;
      default = "/vl-xhttp";
      description = "xHTTP path";
    };
    auth = {
      name = mkOption { type = types.str; default = ""; description = "Username (informational)"; };
      uuid = mkOption { type = types.str; description = "UUID for authentication"; };
    };
  };

  relayInboundOptions = {
    sni = mkOption {
      type = types.str;
      description = "SNI for relay xHTTP inbound (must differ from server's xHTTP SNI)";
    };
  };

  relayTargetOptions = {
    enable = mkEnableOption "relay outbound VLESS over xHTTP";
    serverName = mkOption {
      type = types.str;
      default = "";
      description = "Reality SNI for relay outbound xHTTP";
    };
    path = mkOption {
      type = types.str;
      default = "/vl-xhttp";
      description = "xHTTP path of target server";
    };
  };

  subscriptionUpstreamOptions = {
    enable = mkEnableOption "advertise VLESS+xHTTP in generated subscriptions";
    sni = mkOption { type = types.str; description = "Reality SNI for xHTTP"; };
    path = mkOption { type = types.str; default = "/vl-xhttp"; description = "xHTTP path"; };
  };

  mkServerInbound =
    { cfg, clients, shortIds }:
    {
      listen = "127.0.0.1";
      port = serverPort;
      protocol = "vless";
      tag = "vless-xhttp-in";
      settings = {
        clients = clients.noFlow;
        decryption = "none";
      };
      streamSettings = {
        network = "xhttp";
        security = "reality";
        realitySettings = helpers.mkRealityServerSettings { inherit (cfg) sni; inherit shortIds; };
        xhttpSettings = { path = cfg.path; };
        sockopt.acceptProxyProtocol = true;
      };
    };

  mkRelayInbound =
    { cfg, serverCfg, clients, shortIds }:
    {
      listen = "127.0.0.1";
      port = relayPort;
      protocol = "vless";
      tag = "vless-xhttp-fwd-in";
      settings = {
        clients = clients.noFlow;
        decryption = "none";
      };
      streamSettings = {
        network = "xhttp";
        security = "reality";
        realitySettings = helpers.mkRealityServerSettings { inherit (cfg) sni; inherit shortIds; };
        xhttpSettings = { path = serverCfg.path; };
        sockopt.acceptProxyProtocol = true;
      };
    };

  mkClientOutbound =
    { cfg, realityCfg }:
    helpers.mkVnextOutbound {
      tag = "vless-xhttp-out";
      address = cfg.server;
      port = cfg.port;
      uuid = cfg.auth.uuid;
      streamSettings = {
        network = "xhttp";
        security = "reality";
        realitySettings = helpers.mkRealityClientSettings {
          reality = realityCfg;
          serverName = cfg.serverName;
        };
        xhttpSettings = { path = cfg.path; };
      };
    };

  mkRelayOutbound =
    { cfg, realityCfg, user, serverAddr }:
    helpers.mkVnextOutbound {
      tag = "relay-xhttp-out";
      address = serverAddr;
      port = 443;
      uuid = user.uuid;
      streamSettings = {
        network = "xhttp";
        security = "reality";
        realitySettings = helpers.mkRealityClientSettings {
          reality = realityCfg;
          serverName = cfg.serverName;
        };
        xhttpSettings = { path = cfg.path; };
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
        type = "xhttp";
        path = cfg.path;
        sni = cfg.sni;
        pbk = realityPublicKey;
        sid = shortId;
        fp = fingerprint;
      };
      tag = "vless-xhttp";
    };
}
