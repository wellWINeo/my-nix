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
        WEB_VAULT_FOLDER = "${pkgs.bitwarden_rs-vault}/share/bitwarden_rs/vault";
        WEB_VAULT_ENABLED = true;
        DATA_DIR = "/var/lib/vault";
        IP_HEADER = "X-Real-IP";
        LOG_FILE = "/var/log/bitwarden";
        WEBSOCKET_ENABLED = true;
        WEBSOCKET_ADDRESS = "127.0.0.1";
        WEBSOCKET_PORT = 3012;
        SIGNUPS_VERIFY = true;
        DOMAIN = "https://vault.${cfg.baseDomain}";
        ROCKET_ADDRESS = "127.0.0.1";
        ROCKET_PORT = 8180;
      };

      environmentFile = "/etc/nixos/secrets/vaultwarden.secret.env";
    };
  };
}