# roles/network/xray/hysteria.nix
#
# Hysteria2 protocol module for xray, consumed by server.nix (public inbound)
# and relay.nix (relay inbound plus optional forward outbound). Hysteria2 is
# UDP/QUIC with real TLS (not REALITY) and password auth (not uuid), so it
# does not share the VLESS builder in vless.nix.
#
# Cert/key files are referenced via inert placeholder strings (@HYSTERIA_CERT@/
# @HYSTERIA_KEY@, @HYSTERIA_RELAY_CERT@/@HYSTERIA_RELAY_KEY@). The coordinator
# (default.nix) does NOT string-substitute these sentinels; its jq stage
# overwrites the whole .streamSettings.tlsSettings.certificates[0] object on
# each hysteria inbound at runtime (via LoadCredential), picking the relay
# cert/key when .tag == "hy2-relay-in" and the server cert/key otherwise. The
# placeholders just keep secret material out of the nix store, mirroring how
# the Reality private key is injected.
{ lib }:

with lib;

rec {
  serverInboundTag = "hy2-in";
  relayInboundTag = "hy2-relay-in";
  # Tag of the optional Hysteria2 forward outbound on the relay host; kept
  # under the generic "forward-" selector prefix probed by the forward balancer.
  relayOutboundTag = "forward-hy2-out";
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

      # SHA-256 pin of the remote target certificate, rendered as a single
      # hex string in tlsSettings.pinnedPeerCertSha256. Distinct from a
      # ClientHello fingerprint; never enable this target without
      # deployed-binary pin verification.
      certificateFingerprint = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Pinned SHA256 of the target certificate (single hex string). Used only when insecure = false.";
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

  # --- Builders ---

  # Per-user hysteria auth entries (password-based, unlike VLESS uuid).
  mkHysteriaUsers =
    users:
    map (u: {
      auth = u.password;
      email = "${u.name}@hysteria";
    }) users;

  # hysteriaSettings + TLS block for an inbound. cert/key are inert placeholder
  # strings; the coordinator's jq overwrites certificates[0] wholesale at
  # runtime based on the inbound's tag (see header comment above).
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
      }
      // optionalAttrs (masq != { }) { masquerade = masq; };
      security = "tls";
      tlsSettings = {
        alpn = [ "h3" ];
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
        clients = mkHysteriaUsers users;
      };
      streamSettings = mkInboundStreamSettings cfg;
    };

  mkRelayInbound =
    { cfg, users }:
    let
      base = mkServerInbound { inherit cfg users; };
    in
    base
    // {
      tag = relayInboundTag;
      streamSettings = base.streamSettings // {
        tlsSettings = base.streamSettings.tlsSettings // {
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
    {
      cfg,
      user,
      serverAddr,
    }:
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
        }
        // optionalAttrs cfg.insecure { allowInsecure = true; }
        // optionalAttrs (cfg.certificateFingerprint != null) {
          pinnedPeerCertSha256 = cfg.certificateFingerprint;
        };
      };
    };
}
