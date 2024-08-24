{ config, pkgs, lib, ... }:
with lib;

let
  cfg = config.roles.home-nginx;
in {
  options.roles.home-nginx = {
    enable = mkEnableOption "Enable nginx for home server";
    openFirewall = mkOption { 
      type = types.bool; 
      default = true; 
      description = "Open Firewall";
    };
    ip = mkOption {
      type = types.str;
      description = "IP Address";
    };
  };

  config = mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = optionals cfg.openFirewall [ 80 ];

    services.nginx = {
      enable = true;

      recommendedGzipSettings = true;
      recommendedOptimisation = true;

      virtualHosts.${cfg.ip} = {
        forceSSL = false;
        enableACME = false;
        root = "/etc/www/proxy";
      };
    };

    environment.etc."/www/proxy/proxy.pac".source = ./proxy.pac;
  };
}