{
  config,
  lib,
  pkgs,
  ...
}:
with lib;

let
  cfg = config.roles.calibre;
  port = 8100;
  domain = "ebooks.${cfg.baseDomain}";
  dataDir = "/var/lib/calibre";
  mkSqliteBackup = import ../../common/sqlite-backup.nix;
in
{
  options.roles.calibre = {
    enable = mkEnableOption "Enable Calibre (web)";
    baseDomain = mkOption {
      type = types.str;
      description = "2nd level domain name (base)";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    (mkSqliteBackup {
      inherit lib pkgs;
      name = "calibre";
      databases = [
        "${dataDir}/metadata.db"
        "${dataDir}/app.db"
        "${dataDir}/gdrive.db"
      ];
      backupDir = "/var/backup/calibre";
      user = "calibre-web";
      group = "calibre";
      extraPaths = [ "${dataDir}/" ];
    })
    {
      roles.backup.paths = [ "/var/backup/calibre" ];
      roles.backup.afterServices = [ "backup-calibre.service" ];

      users.groups.calibre = { };

      services.calibre-web = {
        enable = true;
        user = "calibre-web";
        group = "calibre";
        dataDir = dataDir;
        listen = {
          ip = "127.0.0.1";
          port = port;
        };
        options = {
          enableBookUploading = true;
          enableBookConversion = true;
        };
      };

      services.nginx.virtualHosts.${domain} = {
        forceSSL = true;
        enableACME = false;
        sslCertificate = "/var/lib/acme/${cfg.baseDomain}/fullchain.pem";
        sslCertificateKey = "/var/lib/acme/${cfg.baseDomain}/key.pem";
        locations."/" = {
          proxyPass = "http://localhost:${toString port}";
          recommendedProxySettings = true;
        };
        extraConfig = ''
          client_max_body_size 64M;
        '';
      };
    }
  ]);
}
