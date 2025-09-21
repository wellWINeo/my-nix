{ config, lib, ... }:
with lib;

let
  cfg = config.roles.calibre;
  port = 8100;
  domain = "ebooks.${cfg.baseDomain}";
in
{
  options.roles.calibre = {
    enable = mkEnableOption "Enable Calibre (web)";
    baseDomain = mkOption {
      type = types.str;
      description = "2nd level domain name (base)";
    };
  };

  config = mkIf cfg.enable {
    users.groups.calibre = { };

    services.calibre-web = {
      enable = true;
      user = "calibre-web";
      group = "calibre";
      dataDir = "calibre";
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
  };
}
