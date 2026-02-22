{
  config,
  lib,
  ...
}:
with lib;

let
  cfg = config.roles.home-nginx;
in
{
  options.roles.home-nginx = {
    enable = mkEnableOption "Enable nginx for home server";
    ip = mkOption {
      type = types.str;
      description = "IP Address";
    };
  };

  config = mkIf cfg.enable {
    services.nginx = {
      enable = true;

      recommendedGzipSettings = true;
      recommendedOptimisation = true;

      virtualHosts.${cfg.ip} = {
        forceSSL = false;
        enableACME = false;
        root = "/etc/www/proxy";

        extraConfig = ''
          default_type application/x-ns-proxy-autoconfig;
        '';
      };

    };

    environment.etc."/www/proxy/proxy.pac".source = ./proxy.pac;
  };
}
