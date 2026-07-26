{ config, lib, ... }:

with lib;

let
  cfg = config.roles.rss.hub;
in
{
  options.roles.rss.hub.enable = mkEnableOption "RSSHub";

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = config.roles.rss.enable;
        message = "roles.rss.hub requires roles.rss to be enabled";
      }
    ];

    services.rsshub = {
      enable = true;
      redis.enable = false;
      settings = {
        PORT = 1200;
        LISTEN_INADDR_ANY = false;
        CACHE_TYPE = "memory";
      };
    };
  };
}
