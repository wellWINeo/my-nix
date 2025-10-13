{ config, lib, ... }:
with lib;

let
  cfg = config.roles.dav;
in
{
  options.roles.dav = {
    enable = mkEnableOption "Enable DAV (calDAV/cardDAV) server";
    baseDomain = mkOption {
      type = types.str;
      description = "Domain name";
    };
  };

  config = mkIf cfg.enable {
    services.radicale = {
      enable = true;
      settings = {
        auth = {
          type = "htpasswd";
          htpasswd_filename = "/etc/nixos/secrets/radicalePasswd";
          htpasswd_encryption = "autodetect";
        };

        server.hosts =  [ "127.0.0.1:5232" ];

        storage = {
          filesystem_folder = "/var/lib/radicale/collections";
        };

        logging = {
          level = "info";
          mask_passwords = true;
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

    services.nginx.virtualHosts."dav.${cfg.baseDomain}" = {
      forceSSL = true;
      enableACME = false;
      sslCertificate = "/var/lib/acme/${cfg.baseDomain}/fullchain.pem";
      sslCertificateKey = "/var/lib/acme/${cfg.baseDomain}/key.pem";
      
      locations."/" = {
        proxyPass = "http://127.0.0.1:5232/";
        proxyWebsockets = true;
        recommendedProxySettings = true;
      };
    };
  };
}
