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

      recommendedGzipSettings = true;
      recommendedOptimisation = true;

      virtualHosts."0.0.0.0" = {
        root = "/etc/www/${cfg.domain}";
        forceSSL = true;
        enableACME = false;
        sslCertificate = "/var/lib/acme/${cfg.domain}/fullchain.pem";
        sslCertificateKey = "/var/lib/acme/${cfg.domain}/key.pem";
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