{
  config,
  lib,
  ...
}:
with lib;

let
  cfg = config.roles.letsencrypt;
in
{
  options.roles.letsencrypt = {
    enable = mkEnableOption "Enable Let's Encrypt";
    domain = mkOption { type = types.str; };
  };

  config = mkIf cfg.enable {
    security.acme = {
      acceptTerms = true;
      defaults = {
        email = "stepan@${cfg.domain}";
        group = "web";
      };
      certs."${cfg.domain}" = {
        dnsProvider = "cloudflare";
        environmentFile = "/etc/nixos/secrets/cloudflare.ini";
        domain = cfg.domain;
        extraDomainNames = [ "*.${cfg.domain}" ];
      };
    };
  };
}
