{
  config,
  lib,
  pkgs,
  ...
}:
with lib;

let
  cfg = config.roles.blog;
  hostname = "blog.${cfg.baseDomain}";
  port = 8300;
  mkSqliteBackup = import ../common/sqlite-backup.nix;
  assetsDerivation = pkgs.stdenv.mkDerivation {
    name = "Blog assets";
    src = ../assets/blog;
    buildPhase = "";
    installPhase = "cp -r $src $out";
  };
in
{
  options.roles.blog = {
    enable = mkEnableOption "Enable Blog";
    baseDomain = mkOption {
      type = types.str;
      description = "2nd level domain name (base)";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    (mkSqliteBackup {
      inherit lib pkgs;
      name = "writefreely";
      databases = [ "/var/lib/writefreely/writefreely.db" ];
      backupDir = "/var/backup/writefreely";
      user = "writefreely";
      group = "writefreely";
      extraPaths = [ "/var/lib/writefreely/" ];
    })
    {
      users.users.writefreely.uid = 991;
      users.groups.writefreely.gid = 989;

      roles.backup.paths = [ "/var/backup/writefreely" ];
      roles.backup.afterServices = [ "backup-writefreely.service" ];

      services.writefreely = {
        enable = true;
        admin = {
          name = "uspenskiy";
          initialPasswordFile = "/etc/nixos/secrets/writefreelyAdminPassword";
        };
        database.type = "sqlite3";
        host = hostname;
        settings = {
          server.port = port;
          app = {
            site_name = "Stepan Uspenskiy's blog";
            site_description = ''
              Writing about code, internals or just something interesting for me
            '';
            single_user = true;
            federation = false;
            public_stats = false;
            monetization = false;
            wf_modesty = true;
          };
        };
      };

      services.nginx.virtualHosts.${hostname} = {
        forceSSL = true;
        enableACME = false;
        sslCertificate = "/var/lib/acme/${cfg.baseDomain}/fullchain.pem";
        sslCertificateKey = "/var/lib/acme/${cfg.baseDomain}/key.pem";

        locations."/assets/" = {
          alias = assetsDerivation + "/";
          extraConfig = ''
            expires 1y;
            add_header Cache-Control "public, immutable";
          '';
        };

        locations."/" = {
          proxyPass = "http://localhost:${toString port}";
          recommendedProxySettings = true;
        };
      };
    }
  ]);
}
