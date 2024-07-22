{ config, pkgs, lib, ... }:
with lib;

let
  cfg = config.roles.letsencrypt;
in {
  options.roles.letsencrypt = {
    enable = mkEnableOption "Enable Let's Encrypt";
    cloudflareApiKey = mkOption { type = types.str; };
    domain = mkOption { type = types.str; };
  };

  config = mkIf cfg.enable {
    # environment.systemPackages = with pkgs; [
    #   acme
    #   acme-dns-certbot-cloudflare
    # ];

    environment.etc."letsencrypt/cloudflare.ini" = {
      text = ''
      dns_cloudflare_api_token = ${cfg.cloudflareApiKey}
      '';
      mode = "0600";
    };

    security.acme = {
      acceptTerms = true;
      defaults.email = "stepan@${cfg.domain}";
      certs."${cfg.domain}" = {
        dnsProvider = "cloudflare";
        environmentFile = "/etc/letsencrypt/cloudflare.ini";
        domain = cfg.domain;
        extraDomainNames = [ "*.${cfg.domain}" ];
      };
    };
  };
}