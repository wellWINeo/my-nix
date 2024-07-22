{ config, pkgs, lib, ... }:
with lib;

let
  cfg = config.roles.letsencrypt;
  cloudflareEmail = "uspenskiy-03@mail.ru";
in {
  options.roles.letsencrypt = {
    enable = mkEnableOption "Enable Let's Encrypt";
    cloudflareApiKey = mkOption { type = types.str; };
    domain = mkOption { type = types.str; };
  };

  config = mkIf cfg.enable {
    environment.etc."letsencrypt/cloudflare.ini" = {
      text = ''
      DNS_CLOUDFLARE_EMAIL = ${cloudflareEmail}
      CLOUDFLARE_DNS_API_TOKEN = ${cfg.cloudflareApiKey}
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