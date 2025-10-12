{ config, lib, ... }:
with lib;

let
  cfg = config.roles.blog;
  hostname = "blog.${cfg.baseDomain}";
  port = 8300;
in
{
  options.roles.blog = {
    enable = mkEnableOption "Enable Blog";
    baseDomain = mkOption {
      type = types.str;
      description = "2nd level domain name (base)";
    };
  };

  config = mkIf cfg.enable {
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

      locations."/assets" = {
        try_files = "$uri = 404";
      };

      locations."/" = {
        proxyPass = "http://localhost:${toString port}";
        recommendedProxySettings = true;
      };
    };
  };
}
