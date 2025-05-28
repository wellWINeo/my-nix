{
  config,
  pkgs,
  lib,
  ...
}:
with lib;

let
  cfg = config.roles.vault;

  port = 8180;
in
{
  options.roles.vault = {
    enable = mkEnableOption "Enable Vaulwarden";
    baseDomain = mkOption {
      type = types.str;
      description = "Base domain";
    };
    enableWeb = mkEnableOption "Enable web";
  };

  config = mkIf cfg.enable {
    services.vaultwarden = {
      enable = true;
      # backupDir = "/path/to/directory"; # TODO
      config = {
        WEB_VAULT_FOLDER = "${pkgs.bitwarden_rs-vault}/share/vaultwarden/vault";
        WEB_VAULT_ENABLED = true;
        DATA_FOLDER = "/var/lib/vault";
        IP_HEADER = "X-Real-IP";
        LOG_FILE = "/var/log/vaultwarden";
        WEBSOCKET_ENABLED = true;
        WEBSOCKET_ADDRESS = "127.0.0.1";
        WEBSOCKET_PORT = 3012;
        SIGNUPS_VERIFY = true;
        DOMAIN = "https://vault.${cfg.baseDomain}";
        ROCKET_ADDRESS = "127.0.0.1";
        ROCKET_PORT = port;
        SMTP_HOST = "mail.${cfg.baseDomain}";
        SMTP_FROM = "vault@${cfg.baseDomain}";
        SMTP_FROM_NAME = "Vaultwarden";
        SMTP_PORT = 587;
        SMTP_SECURITY = "starttls";
        SMTP_USERNAME = "vault@${cfg.baseDomain}";
        SMTP_AUTH_MECHANISM = "Plain,Login";
        SMTP_TIMEOUT = 60;
        INVITATIONS_ALLOWED = true;
        SIGNUPS_ALLOWED = false;
      };

      environmentFile = "/etc/nixos/secrets/vaultwarden.env";
    };

    services.nginx = mkIf cfg.enableWeb {
      enable = true;

      virtualHosts."vault.${cfg.baseDomain}" = {
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

    systemd.services.vaultwarden = {
      serviceConfig = {
        ReadWritePaths = [
          "/var/log/vaultwarden"
          "/var/lib/vault"
        ];
      };
    };
  };
}
