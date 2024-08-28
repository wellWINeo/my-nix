{ config, pkgs, lib, ... }:
with lib;

let
  cfg = config.roles.obsidian-livesync;
  port = 5984;
in {
  options.roles.obsidian-livesync = {
    enable = mkEnableOption "Enable Obsidian LiveSync";
    domain = mkOption {
      type = types.str;
      description = "Base domain to server CouchDB";
    };
    adminPassword = mkOption {
      type = types.str;
      description = "Password for admin account";
    };
  };

  config = mkIf cfg.enable {
    services.couchdb = {
      enable = true;
      viewIndexDir = "/var/lib/obsidian/index";
      databaseDir = "/var/lib/obsidian/data";
      adminUser = "o__ni";
      adminPass = cfg.adminPassword;
    };

    services.nginx.virtualHosts."obsidian-livesync.${cfg.domain}" = {
      forceSSL = true;
      enableACME = false;

      sslCertificate = "/var/lib/acme/${cfg.domain}/fullchain.pem";
      sslCertificateKey = "/var/lib/acme/${cfg.domain}/key.pem";

      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString port}";
        proxyWebsockets = true;
        recommendedProxySettings = true;
      };
    };
  };
}