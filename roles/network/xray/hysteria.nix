# roles/network/xray/hysteria.nix
#
# Hysteria2 protocol module for xray. Folded into server.nix / relay.nix /
# subscriptions.nix ALONGSIDE the VLESS transports/ registry. Hysteria2 is
# UDP/QUIC with real TLS (not REALITY) and password auth (not uuid), so it
# intentionally does NOT reuse transports/lib.nix (VLESS/Reality helpers).
#
# Cert/key files are referenced via placeholders (@HYSTERIA_CERT@/@HYSTERIA_KEY@)
# that the coordinator (default.nix) rewrites at runtime via jq + LoadCredential,
# mirroring how the Reality private key is injected. This keeps all secret
# material out of the nix store.
{ lib }:

with lib;

rec {
  name = "hysteria2";
  serverInboundTag = "hy2-in";
  relayInboundTag = "hy2-relay-in";
  relayOutboundTag = "relay-hy2-out";
  defaultPort = 36712;

  # --- Option schema fragments (merged into consumers via // ) ---

  serverOptions = {
    hysteria = {
      enable = mkEnableOption "Hysteria2 server inbound (UDP/QUIC, real TLS)";

      port = mkOption {
        type = types.port;
        default = defaultPort;
        description = "UDP port for the Hysteria2 server inbound";
      };

      sni = mkOption {
        type = types.str;
        default = "";
        description = "Camouflage SNI / serverName for the TLS handshake";
      };

      certFile = mkOption {
        type = types.path;
        description = "TLS certificate file path (deployed via secrets; quoted string, no store copy)";
      };

      keyFile = mkOption {
        type = types.path;
        description = "TLS private key file path (deployed via secrets; quoted string, no store copy)";
      };

      pinSHA256 = mkOption {
        type = types.str;
        default = "";
        description = "SHA256 of the cert advertised in subscriptions for client pinning. Empty => insecure=1.";
      };

      masquerade = mkOption {
        type = types.attrs;
        default = { };
        description = "hysteriaSettings.masquerade block (HTTP/3 camouflage). Empty = default 404.";
      };
    };
  };

  relayInboundOptions = {
    hysteria = {
      enable = mkEnableOption "Hysteria2 relay inbound (clients reach this host over QUIC)";

      port = mkOption {
        type = types.port;
        default = defaultPort;
        description = "UDP port for the Hysteria2 relay inbound";
      };

      sni = mkOption {
        type = types.str;
        default = "";
        description = "Camouflage SNI for the relay inbound TLS handshake";
      };

      certFile = mkOption {
        type = types.path;
        description = "TLS certificate file path for the relay inbound";
      };

      keyFile = mkOption {
        type = types.path;
        description = "TLS private key file path for the relay inbound";
      };

      pinSHA256 = mkOption {
        type = types.str;
        default = "";
        description = "SHA256 of the relay inbound cert, advertised for subscription pinning";
      };

      masquerade = mkOption {
        type = types.attrs;
        default = { };
        description = "hysteriaSettings.masquerade block";
      };
    };
  };

  relayTargetOptions = {
    hysteria = {
      enable = mkEnableOption "relay outbound Hysteria2 to the target server (QUIC)";

      serverName = mkOption {
        type = types.str;
        default = "";
        description = "SNI of the target Hysteria2 server";
      };

      pinSHA256 = mkOption {
        type = types.str;
        default = "";
        description = "Pinned SHA256 of the target cert. Used only when insecure = false.";
      };

      insecure = mkOption {
        type = types.bool;
        default = false;
        description = "Skip TLS verification of the target (self-signed certs).";
      };

      port = mkOption {
        type = types.port;
        default = defaultPort;
        description = "Target Hysteria2 UDP port";
      };
    };
  };

  subscriptionUpstreamOptions = {
    hysteria = {
      enable = mkEnableOption "advertise Hysteria2 in generated subscriptions";

      port = mkOption {
        type = types.port;
        default = defaultPort;
        description = "Hysteria2 UDP port advertised to clients";
      };

      sni = mkOption {
        type = types.str;
        description = "SNI clients use for the Hysteria2 connection";
      };

      pinSHA256 = mkOption {
        type = types.str;
        default = "";
        description = "Cert pin advertised to clients. Empty => insecure=1 emitted.";
      };
    };
  };

  # --- Builders ---

  # Per-user hysteria auth entries (password-based, unlike VLESS uuid).
  mkHysteriaUsers =
    users:
    map (u: {
      auth = u.password;
      email = "${u.name}@hysteria";
    }) users;

  # hysteriaSettings + TLS block for an inbound. cert/key are placeholders
  # rewritten at runtime by the coordinator.
  mkInboundStreamSettings =
    cfg:
    let
      masq = cfg.masquerade or { };
    in
    {
      network = "hysteria";
      hysteriaSettings = {
        version = 2;
        auth = "";
        udpIdleTimeout = 60;
      } // optionalAttrs (masq != { }) { masquerade = masq; };
      security = "tls";
      tlsSettings = {
        certificates = [
          {
            certificateFile = "@HYSTERIA_CERT@";
            keyFile = "@HYSTERIA_KEY@";
          }
        ];
      };
    };

  mkServerInbound =
    { cfg, users }:
    {
      listen = "0.0.0.0";
      port = cfg.port;
      protocol = "hysteria";
      tag = serverInboundTag;
      settings = {
        version = 2;
        users = mkHysteriaUsers users;
      };
      streamSettings = mkInboundStreamSettings cfg;
    };

  mkRelayInbound =
    { cfg, users }:
    let
      base = mkServerInbound { inherit cfg users; };
    in
    base // {
      tag = relayInboundTag;
      streamSettings = base.streamSettings // {
        tlsSettings = {
          certificates = [
            {
              certificateFile = "@HYSTERIA_RELAY_CERT@";
              keyFile = "@HYSTERIA_RELAY_KEY@";
            }
          ];
        };
      };
    };

  # Relay outbound (veles -> target). Uses the relay's single `user` (matches
  # the VLESS relay pattern, which uses cfg.user for outbound auth).
  mkRelayOutbound =
    { cfg, user, serverAddr }:
    {
      protocol = "hysteria";
      tag = relayOutboundTag;
      settings = {
        version = 2;
        address = serverAddr;
        port = cfg.port;
      };
      streamSettings = {
        network = "hysteria";
        hysteriaSettings = {
          version = 2;
          auth = user.password;
        };
        security = "tls";
        tlsSettings = {
          serverName = cfg.serverName;
        } // optionalAttrs cfg.insecure { allowInsecure = true; }
        // optionalAttrs (cfg.pinSHA256 != "") {
          pinnedPeerCertificateChainSha256 = [ cfg.pinSHA256 ];
        };
      };
    };

  mkSubscriptionEntry =
    { cfg, user, serverAddr }:
    let
      query =
        if cfg.pinSHA256 != "" then
          "sni=${cfg.sni}&pinSHA256=${cfg.pinSHA256}"
        else
          "sni=${cfg.sni}&insecure=1";
    in
    "hysteria2://${user.password}@${serverAddr}:${toString cfg.port}/?${query}#${name}";
}