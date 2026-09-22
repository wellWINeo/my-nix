{ config, lib, ... }:

with lib;

let
  cfg = config.roles.observability;
  scrapeJobType = types.submodule {
    options = {
      name = mkOption { type = types.str; };
      target = mkOption { type = types.str; };
      metricsPath = mkOption {
        type = types.str;
        default = "/metrics";
      };
      scheme = mkOption {
        type = types.enum [
          "http"
          "https"
        ];
        default = "http";
      };
      host = mkOption {
        type = types.str;
        default = config.networking.hostName;
        description = "Host label for this job's targets";
      };
    };
  };
in
{
  imports = [
    ./node-exporter.nix
    ./victoria-metrics.nix
    ./grafana.nix
  ];

  options.roles.observability = {
    enable = mkEnableOption "observability stack";
    baseDomain = mkOption { type = types.str; };

    agent = {
      enable = mkEnableOption "node-side metrics agent (exporters + textfile collectors)";

      textfileDir = mkOption {
        type = types.str;
        default = "/var/lib/prometheus-node-exporter-textfiles";
        description = "Directory harvested by node_exporter's textfile collector";
      };
    };

    remoteAgents = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            host = mkOption {
              type = types.str;
              description = "Hostname label; also the MagicDNS name prefix (<host>.<tailnetDomain>)";
            };
            port = mkOption {
              type = types.port;
              default = 9100;
              description = "node_exporter port on the agent";
            };
          };
        }
      );
      default = [ ];
      description = "Tailnet hosts scraped by this VictoriaMetrics via the node job";
    };

    scrapeJobs = mkOption {
      type = types.listOf scrapeJobType;
      default = [ ];
      internal = true;
      description = "Native Prometheus scrape targets registered by their owning roles.";
    };
  };

  config = mkIf cfg.enable {
    roles.vpn.metrics.enable = mkDefault true;
    roles.rss.metrics.enable = mkDefault true;
    roles.mail.metrics.enable = mkDefault true;
  };
}
