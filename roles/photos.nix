{
  config,
  lib,
  ...
}:
with lib;

let
  cfg = config.roles.photos;
  port = 2342;
in
{

  options.roles.photos = {
    enable = mkEnableOption "Enable Photos storage";
    hostName = mkOption {
      type = types.str;
    };
    storagePath = mkOption {
      type = types.path;
    };
  };

  config = mkIf cfg.enable {
    services.photoprism = {
      enable = true;
      port = port;
      storagePath = cfg.storagePath;
      originalsPath = "${cfg.storagePath}/originals";
      passwordFile = "/etc/nixos/secrets/photoPrismPassword";
      address = "0.0.0.0";
    };

    services.nginx.virtualHosts = {
      "photos.${cfg.hostName}" = {
        forceSSL = false;
        enableACME = false;
        locations."/" = {
          proxyPass = "http://localhost:${toString port}";
        };
      };
    };
  };
}
