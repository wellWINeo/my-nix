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
    };
  };
in
{
  imports = [
    ./node-exporter.nix
    ./victoria-metrics.nix
  ];

  options.roles.observability = {
    enable = mkEnableOption "observability stack";
    baseDomain = mkOption { type = types.str; };
    scrapeJobs = mkOption {
      type = types.listOf scrapeJobType;
      default = [ ];
      internal = true;
      description = "Native Prometheus scrape targets registered by their owning roles.";
    };
  };
}
