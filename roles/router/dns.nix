{ config, pkgs, lib, ... }:
with lib;

###
# Update digest:
# echo | openssl s_client -connect '1.1.1.1:853' 2>/dev/null | openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | openssl enc -base64
###

let
  cfg = config.roles.dns;
in {
  options.roles.dns.enable = mkEnableOption "Enable DNS";

  config = mkIf cfg.enable {
    services.stubby = {
      enable = true;
      settings = pkgs.stubby.passthru.settingsExample // {
        listen_addresses = [ "127.0.0.1@8053" ];
        upstream_recursive_servers = [
          {
            address_data = "1.1.1.1";
            tls_auth_name = "cloudflare-dns.com";
            tls_pubkey_pinset = [{
              digest = "sha256";
              value = "HdDBgtnj07/NrKNmLCbg5rxK78ZehdHZ/Uoutx4iHzY=";
            }];
          }

          {
            address_data = "1.0.0.1";
            tls_auth_name = "cloudflare-dns.com";
            tls_pubkey_pinset = [{
              digest = "sha256";
              value = "HdDBgtnj07/NrKNmLCbg5rxK78ZehdHZ/Uoutx4iHzY=";
            }];
          }
        ];
      };
    };
  };
}