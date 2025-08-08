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
          extraConfig = ''
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header Host $host;

            proxy_buffering off;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";

            client_max_body_size 500M;
          '';
        };
      };
    };
  };
}
