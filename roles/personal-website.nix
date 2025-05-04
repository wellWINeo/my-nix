{ config, pkgs, lib, ... }:
with lib;

let
  cfg = config.roles.personelWebsite;
in {
  options.roles.personelWebsite = {
    enable = mkEnableOption "Enable personel website";
    openFirewall = mkOption { 
      type = types.bool; 
      default = true; 
      description = "Open Firewall";
    };
    domain = mkOption { 
      type = types.str; 
      description = "Domain name"; 
    };
  };

  config = mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = optionals cfg.openFirewall [ 80 443 ];

    services.nginx = {
      enable = true;
      group = "web";

      config = ''
        access_log syslog:server=unix:/dev/log
      ''; 

      recommendedGzipSettings = true;
      recommendedOptimisation = true;

      virtualHosts."${cfg.domain}" = {
        root = "/etc/www/${cfg.domain}";
        forceSSL = true;
        enableACME = false;
        sslCertificate = "/var/lib/acme/${cfg.domain}/fullchain.pem";
        sslCertificateKey = "/var/lib/acme/${cfg.domain}/key.pem";

        locations."/cv" = {
          tryFiles = "$uri.pdf = 404";
          extraConfig = "add_header Content-Disposition \"inline; filename=Stepan Uspenkiy (CV).pdf\";";
        };

        locations."/" = {
          tryFiles = "$uri $uri/ =404";
        };
      };

      virtualHosts."vault.${cfg.domain}" = {
        forceSSL = true;
        enableACME = false;

        sslCertificate = "/var/lib/acme/${cfg.domain}/fullchain.pem";
        sslCertificateKey = "/var/lib/acme/${cfg.domain}/key.pem";

        locations."/" = {
          proxyPass = "http://127.0.0.1:8180";
          proxyWebsockets = true;
          recommendedProxySettings = true;
        };
      };

      virtualHosts."gw.${cfg.domain}" = {
        forceSSL = true;
        enableACME = false;

        sslCertificate = "/var/lib/acme/${cfg.domain}/fullchain.pem";
        sslCertificateKey = "/var/lib/acme/${cfg.domain}/key.pem";

        locations."/".return = "301 https://google.com/search?q=$request_uri";

        locations."/fckrkn" = {
          proxyPass = "http://127.0.0.1:8388/";
          extraConfig = ''
            proxy_redirect off;
            proxy_buffering off;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";          
          '';
        };
      };
    };

    environment.etc."/www/${cfg.domain}".source = pkgs.fetchFromGitHub {
      owner = "wellWINeo";
      repo = "PersonalSite";
      rev = "e22576072440c3d4ca1104ee92f996f58cfe6832";
      sha256 = "1yvwp932pgkzl0gaha4jk3rhqwmhbshqi2abz0gs6i23hwp97f22";
    };
  };
}