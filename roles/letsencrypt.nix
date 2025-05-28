{
  config,
  lib,
  ...
}:
with lib;

let
  cfg = config.roles.letsencrypt;

  firstDomain = elemAt cfg.domains 0;
in
{
  options.roles.letsencrypt = {
    enable = mkEnableOption "Enable Let's Encrypt";
    domains =
      with types;
      mkOption {
        type = listOf str;
        default = [ ];
        description = "List of domains to issue certificates";
      };
    domain = mkOption { type = types.str; };
  };

  config = mkIf cfg.enable {
    security.acme = {
      acceptTerms = true;
      defaults = {
        email = "stepan@${firstDomain}";
        group = "web";
      };

      certs = listToAttrs (
        map (domain: {
          name = domain;
          value = {
            dnsProvider = "cloudflare";
            environmentFile = "/etc/nixos/secrets/cloudflare.ini";
            domain = domain;
            extraDomainNames = [ "*.${domain}" ];
          };
        }) cfg.domains
      );
    };
  };
}
