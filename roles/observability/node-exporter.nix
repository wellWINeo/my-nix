{ config, lib, ... }:

with lib;

let
  cfg = config.roles.observability;
in
{
  config = mkIf cfg.enable {
    services.prometheus.exporters.node = {
      enable = true;
      listenAddress = "127.0.0.1";
      enabledCollectors = [ "systemd" ];
    };

    roles.observability.scrapeJobs = mkAfter [
      {
        name = "node";
        target = "127.0.0.1:9100";
      }
    ];
  };
}
