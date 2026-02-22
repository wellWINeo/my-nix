{
  config,
  lib,
  ...
}:
with lib;

let
  cfg = config.roles.n8n;
  domainName = "n8n.${cfg.hostname}";
  port = 5678;
in
{
  options.roles.n8n = {
    enable = mkEnableOption "Enable n8n workflow automation tool";
    hostname = mkOption {
      type = types.str;
      description = "Base hostname for n8n service";
    };
  };

  config = mkIf cfg.enable {
    services.n8n = {
      enable = true;
      openFirewall = false;
      environment = {
        N8N_PORT = port;
      };
    };

    services.nginx.virtualHosts.${domainName} = {
      forceSSL = true;
      enableACME = false;
      sslCertificate = "/var/lib/acme/${cfg.hostname}/fullchain.pem";
      sslCertificateKey = "/var/lib/acme/${cfg.hostname}/key.pem";

      locations."/" = {
        proxyPass = "http://localhost:${toString port}";
        recommendedProxySettings = true;
        proxyWebsockets = true;
      };
    };
  };
}
