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
  };

  config = mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = optionals cfg.openFirewall [ 80 443 ];

    services.nginx = {
      enable = true;
      virtualHosts."uspenskiy.su" = {
        root = "/var/www/uspenskiy.su";
      };
    };

    environment.etc."/var/www/uspenskiy.su".source = pkgs.fetchFromGitHub {
      owner = "wellWINeo";
      repo = "PersonalSite";
      rev = "d2f739f159b94928d552e0b033820fd6e25abb36";
      sha256 = "1cxmlnir561qh7dm6pn5557m6w6sygidihc51yh6bk1j08y4l64s";
    };
  };
}