{ config, lib, ... }:

with lib;

let
  cfg = config.roles.observability;
  hostname = "grafana.${cfg.baseDomain}";
in
{
  config = mkIf cfg.enable {
    services.grafana = {
      enable = true;
      settings = {
        server = {
          domain = hostname;
          root_url = "https://${hostname}/";
          enforce_domain = true;
          http_port = 3000;
        };
        security = {
          cookie_secure = true;
          cookie_samesite = "lax";
          secret_key = "$__env{GF_SECURITY_SECRET_KEY}";
        };
        users.allow_sign_up = false;
        "auth.anonymous".enabled = false;
        metrics.enabled = true;
      };
      provision = {
        enable = true;
        datasources.settings = {
          apiVersion = 1;
          datasources = [
            {
              name = "VictoriaMetrics";
              uid = "victoriametrics";
              type = "prometheus";
              access = "proxy";
              url = "http://127.0.0.1:8428";
              isDefault = true;
              editable = false;
            }
          ];
        };
        dashboards.settings = {
          apiVersion = 1;
          providers = [
            {
              name = "mokosh";
              type = "file";
              disableDeletion = true;
              editable = false;
              options.path = ./dashboards;
            }
          ];
        };
      };
    };

    systemd.services.grafana.serviceConfig.EnvironmentFile = "/etc/nixos/secrets/grafana.env";

    roles.observability.scrapeJobs = mkAfter [
      {
        name = "grafana";
        target = "127.0.0.1:3000";
      }
    ];

    services.nginx.virtualHosts.${hostname} = {
      forceSSL = true;
      enableACME = false;
      sslCertificate = "/var/lib/acme/${cfg.baseDomain}/fullchain.pem";
      sslCertificateKey = "/var/lib/acme/${cfg.baseDomain}/key.pem";
      locations."= /metrics".return = "404";
      locations."/" = {
        proxyPass = "http://127.0.0.1:3000";
        recommendedProxySettings = true;
      };
    };
  };
}
