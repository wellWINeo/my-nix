{
  config,
  lib,
  pkgs,
  ...
}:
with lib;

let
  cfg = config.roles.webmail;
  port = cfg.port;
  dataDir = "/var/lib/bulwark-webmail";
in
{
  options.roles.webmail = {
    enable = mkEnableOption "Enable Bulwark webmail client";

    baseDomain = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Base domain for SSL certs and hostname derivation";
    };

    port = mkOption {
      type = types.int;
      default = 11080;
      description = "Internal port for the webmail service";
    };

    jmapServerUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "JMAP server URL to connect to";
    };

    sessionSecretFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "File containing the session secret for encrypting sessions";
    };

    stalwartFeatures = mkOption {
      type = types.bool;
      default = true;
      description = "Enable Stalwart-specific features (password change, sieve filters)";
    };
  };

  config = mkIf cfg.enable (
    let
      webmailHostname = "webmail.${cfg.baseDomain}";
    in
    {
      assertions = [
        {
          assertion = cfg.baseDomain != null;
          message = "roles.webmail.baseDomain must be set";
        }
        {
          assertion = cfg.jmapServerUrl != null;
          message = "roles.webmail.jmapServerUrl must be set";
        }
        {
          assertion = cfg.sessionSecretFile != null;
          message = "roles.webmail.sessionSecretFile must be set for production deployments";
        }
      ];

      systemd.services.bulwark-webmail = {
        description = "Bulwark Webmail";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];

        environment = {
          HOSTNAME = "127.0.0.1";
          PORT = toString port;
          NODE_ENV = "production";
          NEXT_TELEMETRY_DISABLED = "1";
          JMAP_SERVER_URL = cfg.jmapServerUrl;
          STALWART_FEATURES = if cfg.stalwartFeatures then "true" else "false";
          SETTINGS_SYNC_ENABLED = "true";
          SETTINGS_DATA_DIR = "${dataDir}/data/settings";
          ADMIN_CONFIG_DIR = "${dataDir}/data/admin";
          ADMIN_STATE_DIR = "${dataDir}/data/admin-state";
          TELEMETRY_DATA_DIR = "${dataDir}/data/telemetry";
        }
        // optionalAttrs (cfg.sessionSecretFile != null) {
          SESSION_SECRET_FILE = cfg.sessionSecretFile;
        };

        serviceConfig = {
          DynamicUser = true;
          StateDirectory = "bulwark-webmail";
          WorkingDirectory = dataDir;
          ExecStart = "${pkgs.nodejs_24}/bin/node ${pkgs.bulwark-webmail}/server.js";
          Restart = "on-failure";
          RestartSec = "5";

          ExecStartPre = [
            "${pkgs.coreutils}/bin/mkdir -p ${dataDir}/data/settings ${dataDir}/data/admin ${dataDir}/data/admin-state ${dataDir}/data/telemetry"
          ];

          ReadWritePaths = [ dataDir ];

          CapabilityBoundingSet = [ "" ];
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictNamespaces = true;
          LockPersonality = true;
        };
      };

      services.nginx = {
        enable = true;
        virtualHosts.${webmailHostname} = {
          forceSSL = true;
          enableACME = false;
          sslCertificate = "/var/lib/acme/${cfg.baseDomain}/fullchain.pem";
          sslCertificateKey = "/var/lib/acme/${cfg.baseDomain}/key.pem";

          locations."/" = {
            proxyPass = "http://127.0.0.1:${toString port}";
            proxyWebsockets = true;
            recommendedProxySettings = true;
          };
        };
      };
    }
  );
}
