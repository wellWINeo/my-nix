{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.roles.vpn;
  dataDir = "/var/lib/headscale";
  backupDir = "/var/backup/headscale";
  headscalePort = 8080;
  headplanePort = 3000;
  mkSqliteBackup = import ../common/sqlite-backup.nix;
in
{
  options.roles.vpn = {
    enable = mkEnableOption "self-hosted Headscale VPN control plane";
    hostname = mkOption { type = types.str; };
    certificateDirectory = mkOption { type = types.str; };
    publicIPv4 = mkOption { type = types.str; };
  };

  config = mkIf cfg.enable (mkMerge [
    (mkSqliteBackup {
      inherit lib pkgs;
      name = "headscale";
      databases = [ "${dataDir}/db.sqlite" ];
      backupDir = backupDir;
      user = "headscale";
      group = "headscale";
      extraPaths = [
        "${dataDir}/noise_private.key"
        "${dataDir}/derp_server_private.key"
      ];
    })
    {
      services.headscale = {
        enable = true;
        address = "127.0.0.1";
        port = headscalePort;
        settings = {
          server_url = "https://${cfg.hostname}";
          database = {
            type = "sqlite";
            sqlite = {
              path = "${dataDir}/db.sqlite";
              write_ahead_log = true;
            };
          };
          dns = {
            magic_dns = false;
            override_local_dns = false;
          };
          derp = {
            urls = [ ];
            auto_update_enabled = false;
            server = {
              enabled = true;
              ipv4 = cfg.publicIPv4;
            };
          };
        };
      };

      services.headplane = {
        enable = true;
        settings = {
          server = {
            host = "127.0.0.1";
            port = headplanePort;
            base_url = "https://${cfg.hostname}";
            cookie_secret_path = "/etc/nixos/secrets/headplane-cookie-secret";
            cookie_secure = true;
          };
          headscale = {
            url = "http://127.0.0.1:${toString headscalePort}";
            public_url = "https://${cfg.hostname}";
          };
          integration.proc.enabled = false;
        };
      };

      services.nginx.virtualHosts.${cfg.hostname} = {
        forceSSL = true;
        enableACME = false;
        sslCertificate = "${cfg.certificateDirectory}/fullchain.pem";
        sslCertificateKey = "${cfg.certificateDirectory}/key.pem";

        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString headscalePort}";
          proxyWebsockets = true;
          recommendedProxySettings = true;
        };

        locations."/admin/" = {
          proxyPass = "http://127.0.0.1:${toString headplanePort}";
          proxyWebsockets = true;
          recommendedProxySettings = true;
          basicAuthFile = "/etc/nixos/secrets/headplane.htpasswd";
          extraConfig = "proxy_buffering off;";
        };
      };

      networking.firewall.allowedUDPPorts = [ 3478 ];
      roles.backup.paths = [ backupDir ];
      roles.backup.afterServices = [ "backup-headscale.service" ];
    }
  ]);
}
