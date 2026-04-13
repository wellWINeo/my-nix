# roles/network/sni-router.nix
#
# Shared SNI-based TLS routing via nginx stream.
# Other modules register entries via roles.sni-router.entries.
{
  config,
  lib,
  ...
}:

with lib;

let
  cfg = config.roles.sni-router;

  defaultBackend =
    if cfg.defaultBackend != null then
      cfg.defaultBackend
    else if cfg.entries != [ ] then
      (builtins.head cfg.entries).backend
    else
      "127.0.0.1:9000";
in
{
  options.roles.sni-router = {
    enable = mkEnableOption "SNI-based TLS routing via nginx stream";

    port = mkOption {
      type = types.port;
      default = 443;
      description = "External port to listen on";
    };

    entries = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            sni = mkOption {
              type = types.str;
              description = "SNI hostname to match";
            };
            backend = mkOption {
              type = types.str;
              description = "Backend address (e.g. 127.0.0.1:9000)";
            };
            proxyProtocol = mkOption {
              type = types.bool;
              default = true;
              description = "Whether to emit proxy_protocol to this backend";
            };
          };
        }
      );
      default = [ ];
      description = "List of SNI → backend mappings";
    };

    defaultBackend = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Fallback backend; defaults to first entry if null";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.entries != [ ];
        message = "roles.sni-router requires at least one entry";
      }
    ];

    services.nginx = {
      enable = true;
      streamConfig = ''
        map $ssl_preread_server_name $sni_backend {
        ${
          lib.concatMapStrings (e: "    ${e.sni}  ${e.backend};\n") cfg.entries
        }    default  ${defaultBackend};
        }

        server {
          listen ${toString cfg.port};
          ssl_preread on;
          proxy_pass $sni_backend;
          proxy_protocol on; # all registered backends are expected to accept proxy protocol
        }
      '';
    };

    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
