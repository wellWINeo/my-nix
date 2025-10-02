{ config, lib, ... }:
with lib;

let
  cfg = config.roles.dav;
in
{
  options.roles.dav = {
    enable = mkEnableOption "Enable DAV (calDAV/cardDAV) server";
    domain = mkOption {
      type = types.str;
      description = "Domain name";
    };
  };

  config = mkIf cfg.enable {
    services.radicale = {
      enable = true;
      settings = {
        server = {
          hosts = [ "127.0.0.1:5232" ];

          auth = {
            type = "htpasswd";
            htpasswd_filename = "/etc/nixos/secrets";
            htpasswd_encryption = "autodetect";
          };

          storage = {
            filesystem_folder = "/var/lib/radicale/collections";
          };
        };
      };
      rights = {
        root = {
          user = ".+";
          collection = "";
          permissions = "R";
        };
        principal = {
          user = ".+";
          collection = "{user}";
          permissions = "RW";
        };
        calendars = {
          user = ".+";
          collection = "{user}/[^/]+";
          permissions = "rw";
        };
      };

    };

    services.nginx.virtualHosts.${cfg.domain} = {
      forceSSL = true;
      enableACME = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:5232/";
        proxyWebsockets = true;
        recommendedProxySettings = true;
      };
    };
  };
}
