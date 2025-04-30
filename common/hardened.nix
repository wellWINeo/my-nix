{ config, pkgs, lib, ... }:
with lib;

let
  cfg = config.roles.hardened;
in {
  options.roles.hardened = {
    enable = mkEnableOption "Enable server hardenings";
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ pkgs.fail2ban ];

    services.fail2ban = {
      enable = true;
      maxretry = 5;
      jails = {
        sshd = {
          settings = {
            port = "ssh";
            filter = "sshd";
            logpath = "/var/log/auth.log";
          };
        };
        nginx = {
          settings = {
            port = "http,https";
            filter = "nginx-http-auth";
            logpath = "/var/log/auth.log";
          };
        };
        wireguard = {
          settings = {
            port = "51820";
            filter = "wg-access";
            logpath = "/var/log/auth.log";
          };
        };
      };
    };
  };
}