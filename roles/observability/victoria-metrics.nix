{ config, lib, ... }:

with lib;

let
  cfg = config.roles.observability;

  nodeStaticConfigs =
    (optional config.roles.observability.agent.enable {
      targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.node.port}" ];
      labels.host = config.networking.hostName;
    })
    ++ map (a: {
      targets = [ "${a.host}.${config.roles.vpn.tailnetDomain}:${toString a.port}" ];
      labels.host = a.host;
    }) cfg.remoteAgents;

  scrapeConfigs =
    (optional (nodeStaticConfigs != [ ]) {
      job_name = "node";
      static_configs = nodeStaticConfigs;
    })
    ++ map (job: {
      job_name = job.name;
      metrics_path = job.metricsPath;
      scheme = job.scheme;
      static_configs = [
        {
          targets = [ job.target ];
          labels.host = job.host;
        }
      ];
    }) cfg.scrapeJobs;
in
{
  config = mkIf cfg.enable {
    services.victoriametrics = {
      enable = true;
      listenAddress = "127.0.0.1:8428";
      retentionPeriod = "30d";
      prometheusConfig = {
        global.scrape_interval = "60s";
        scrape_configs = scrapeConfigs;
      };
    };

    roles.observability.scrapeJobs = mkAfter [
      {
        name = "victoriametrics";
        target = "127.0.0.1:8428";
      }
    ];
  };
}
