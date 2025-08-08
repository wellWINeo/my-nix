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

    services.avahi.extraServiceFiles.photoprism = ''
      <?xml version="1.0" standalone='no'?><!--*-nxml-*-->
      <!DOCTYPE service-group SYSTEM "avahi-service.dtd">
      <service-group>
        <name replace-wildcards="yes">PhotoPrism on %h</name>
        <service>
          <type>_http._tcp</type>
          <domain-name>photos.${cfg.hostName}</domain-name>
          <port>80</port>
          <txt-record>path=/</txt-record>
        </service>
      </service-group>
    '';
  };
}
