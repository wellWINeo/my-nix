{ config, lib, ... }:

with lib;

let
  cfg = config.roles.observability;
  scrapeConfigs = map (job: {
    job_name = job.name;
    metrics_path = job.metricsPath;
    scheme = job.scheme;
    static_configs = [
      {
        targets = [ job.target ];
        labels.host = "mokosh";
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
