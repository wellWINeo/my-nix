{
  config,
  lib,
  pkgs,
  ...
}:
with lib;

let
  cfg = config.roles.rss;
  minifluxUrl = "localhost:8200";
in
{
  options.roles.rss = {
    enable = mkEnableOption "Enable RSS";
    baseDomain = mkOption {
      type = types.str;
      description = "2nd level domain name (base)";
    };
  };

  config = mkIf cfg.enable {
    services.miniflux = {
      enable = true;
      createDatabaseLocally = true;
      adminCredentialsFile = "/etc/nixos/secrets/minifluxAdminCredentials";
      config = {
        LISTEN_ADDR = minifluxUrl;
        CLEANUP_FREQUENCY = 48;
        ADMIN_USERNAME = "o__ni";
        CREATE_ADMIN = 1;
      };
    };

    services.postgresql.package = pkgs.postgresql_16;

    services.nginx.virtualHosts."rss.${cfg.baseDomain}" = {
      forceSSL = true;
      enableACME = false;
      sslCertificate = "/var/lib/acme/${cfg.baseDomain}/fullchain.pem";
      sslCertificateKey = "/var/lib/acme/${cfg.baseDomain}/key.pem";
      locations."/" = {
        proxyPass = "http://${minifluxUrl}";
        recommendedProxySettings = true;
      };
    };
  };
}
