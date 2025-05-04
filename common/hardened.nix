{ config, pkgs, lib, ... }:
with builtins;
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

      jails = let
        mkJail = filterName: {
          settings = {
            port = "http,https";
            filter = filterName;
          };
        };
        filterNames = [
          "nginx-http-auth"
          "nginx-bad-request"
          "nginx-botsearch"
          "nginx-error-common"
          "nginx-forbidden"
        ];
        nginxJails = listToAttrs (map (f: {
          name = f;
          value = mkJail f;
        }) filterNames);
      in 
        nginxJails // { 
          sshd = {
            settings = {
              port = "ssh";
              filter = "sshd";
              logpath = "/var/log/auth.log";
            };
          };  
        };
    };
  };
}