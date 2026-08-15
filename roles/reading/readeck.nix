{
  config,
  lib,
  pkgs,
  ...
}:
with lib;

let
  cfg = config.roles.readeck;
  hostname = "readlater.${cfg.baseDomain}";
  port = 8000;
  dataDir = "/var/lib/readeck";
  backupDir = "/var/backup/readeck";
  mkSqliteBackup = import ../../common/sqlite-backup.nix;
in
{
  options.roles.readeck = {
    enable = mkEnableOption "Enable Readeck";
    baseDomain = mkOption {
      type = types.str;
      description = "2nd level domain name (base)";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    (mkSqliteBackup {
      inherit lib pkgs;
      name = "readeck";
      databases = [ "${dataDir}/db.sqlite3" ];
      backupDir = backupDir;
      user = "root";
      group = "root";
      extraPaths = [ "${dataDir}/" ];
    })
    {
      roles.backup.paths = [ backupDir ];
      roles.backup.afterServices = [ "backup-readeck.service" ];

      services.readeck = {
        enable = true;
        environmentFile = "/etc/nixos/secrets/readeck.env";
        settings = {
          main.data_directory = dataDir;
          server = {
            host = "127.0.0.1";
            port = port;
            allowed_hosts = [ hostname ];
            trusted_proxies = [ "127.0.0.1" ];
            base_url = "https://${hostname}";
          };
          database.source = "sqlite3:${dataDir}/db.sqlite3";
        };
      };

      services.nginx.virtualHosts.${hostname} = {
        forceSSL = true;
        enableACME = false;
        sslCertificate = "/var/lib/acme/${cfg.baseDomain}/fullchain.pem";
        sslCertificateKey = "/var/lib/acme/${cfg.baseDomain}/key.pem";
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString port}";
          recommendedProxySettings = true;
        };
        extraConfig = ''
          client_max_body_size 50M;
          proxy_buffering off;
        '';
      };
    }
  ]);
}
