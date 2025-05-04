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
            backend = "systemd";
          };
        };

        nginx-badbots = {
          settings = {
            port = "http,https";
            filter = "nginx-badbots";
            backend = "systemd";
          };
        };

        nginx-noscript = {
          settings = {
            port = "http,https";
            filter = "nginx-noscript";
            backend = "systemd";
          };
        };

        nginx-proxy = {
          settings = {
            port = "http,https";
            filter = "nginx-proxy";
            backend = "systemd";
          };
        };
      };
    };
  };
}