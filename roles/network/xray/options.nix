# roles/network/xray/options.nix
#
# Shared option builders for xray transport configuration.
# Used by client.nix (full options) and relay.nix (target options, no server/port/auth).
{ lib }:

with lib;

{
  # Reality TLS client options (for connecting TO an xray server).
  mkRealityClientOptions =
    {
      defaults ? { },
    }:
    {
      enable = mkEnableOption "Reality TLS";

      publicKey = mkOption {
        type = types.str;
        default = defaults.publicKey or "";
        description = "Server's Reality public key";
      };

      shortId = mkOption {
        type = types.str;
        default = defaults.shortId or "";
        description = "Authorized shortId for authentication";
      };

      serverName = mkOption {
        type = types.str;
        default = defaults.serverName or "";
        description = "SNI to present during TLS handshake (fallback when transport doesn't override)";
      };

      fingerprint = mkOption {
        type = types.str;
        default = defaults.fingerprint or "chrome";
        description = "uTLS fingerprint (chrome, firefox, safari, etc.)";
      };
    };

  # VLESS TCP transport options.
  # When includeConnection = true, includes server/port/auth (for client).
  # When false, only includes serverName (for relay target).
  mkVlessTcpOptions =
    {
      includeConnection ? true,
      defaults ? { },
    }:
    {
      enable = mkEnableOption "VLESS over direct TCP with Vision flow";

      serverName = mkOption {
        type = types.str;
        default = defaults.serverName or "";
        description = "Reality SNI for this transport (overrides shared reality.serverName)";
      };
    }
    // optionalAttrs includeConnection {
      server = mkOption {
        type = types.str;
        description = "Server domain or IP";
      };

      port = mkOption {
        type = types.port;
        default = defaults.port or 443;
        description = "Server port";
      };

      auth = {
        name = mkOption {
          type = types.str;
          default = "";
          description = "Username (informational only; xray VLESS uses UUID)";
        };
        uuid = mkOption {
          type = types.str;
          description = "UUID for authentication";
        };
      };
    };

  # VLESS gRPC transport options.
  mkVlessGrpcOptions =
    {
      includeConnection ? true,
      defaults ? { },
    }:
    {
      enable = mkEnableOption "VLESS over gRPC";

      serviceName = mkOption {
        type = types.str;
        default = defaults.serviceName or "VlGrpc";
        description = "gRPC service name (must match server)";
      };

      serverName = mkOption {
        type = types.str;
        default = defaults.serverName or "";
        description = "Reality SNI for this transport (overrides shared reality.serverName)";
      };
    }
    // optionalAttrs includeConnection {
      server = mkOption {
        type = types.str;
        description = "Server domain or IP";
      };

      port = mkOption {
        type = types.port;
        default = defaults.port or 443;
        description = "Server port";
      };

      auth = {
        name = mkOption {
          type = types.str;
          default = "";
          description = "Username (informational only)";
        };
        uuid = mkOption {
          type = types.str;
          description = "UUID for authentication";
        };
      };
    };

  # VLESS xHTTP transport options.
  mkVlessXhttpOptions =
    {
      includeConnection ? true,
      defaults ? { },
    }:
    {
      enable = mkEnableOption "VLESS over xHTTP";

      path = mkOption {
        type = types.str;
        default = defaults.path or "/vl-xhttp";
        description = "xHTTP path";
      };

      serverName = mkOption {
        type = types.str;
        default = defaults.serverName or "";
        description = "Reality SNI for this transport (overrides shared reality.serverName)";
      };
    }
    // optionalAttrs includeConnection {
      server = mkOption {
        type = types.str;
        description = "Server domain or IP";
      };

      port = mkOption {
        type = types.port;
        default = defaults.port or 443;
        description = "Server port";
      };

      auth = {
        name = mkOption {
          type = types.str;
          default = "";
          description = "Username (informational only)";
        };
        uuid = mkOption {
          type = types.str;
          description = "UUID for authentication";
        };
      };
    };
}
