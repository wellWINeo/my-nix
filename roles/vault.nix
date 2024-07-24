{ config, pkgs, lib, ... }: 
with lib;

let
  cfg = config.roles.vault;
in {
  options.roles.vault = {
    enable = mkEnableOption "Enabl Vaulwarden";
    baseDomain = mkOption { 
      type = types.str;
      description = "Base domain";
    };
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
        ROCKET_PORT = 8180;
        SMTP_HOST = mail.uspenskiy.su;
        SMTP_FROM = "vault@uspenskiy.su";
        SMTP_FROM_NAME = "Vaultwarden";
        SMTP_PORT = 587;
        SMTP_SSL = true;
        SMTP_USERNAME = "vault";
        SMTP_AUTH_MECHANISM = "Plain";
        SMTP_TIMEOUT = 15;
        INVITATIONS_ALLOWED = true;
        SIGNUPS_ALLOWED = false;
      };

      environmentFile = "/etc/nixos/secrets/vaultwarden.secret.env";
    };

    systemd.services.vaultwarden = {
      serviceConfig = {
        ReadWritePaths = [ "/var/log/vaultwarden" ];
      };
    };
  };
}