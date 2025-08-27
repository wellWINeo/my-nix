{
  config,
  pkgs,
  lib,
  ...
}:
with lib;

###
# Update digest:
# echo | openssl s_client -connect '1.1.1.1:853' 2>/dev/null | openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | openssl enc -base64
###

let
  cfg = config.roles.dns;
in
{
  options.roles.dns = {
    enable = mkEnableOption "Enable DNS";
    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open Firewall";
    };
    useLocalDNS = mkOption {
      type = types.bool;
      default = true;
      description = "Use local DNS by machine itself";
    };
    ipAddress = mkOption {
      type = types.str;
      description = "IP address";
    };
  };

  config = mkIf cfg.enable {
    networking = {
      firewall.allowedUDPPorts = optionals cfg.openFirewall [ 53 9053 ];
      nameservers = optionals cfg.useLocalDNS [ "127.0.0.1" ];
    };

    services.dnsmasq = {
      enable = true;
      settings = {
        no-resolv = true;
        server = [ "127.0.0.1#8053" ];
        address = ''
          /photos.nixpi/${cfg.ipAddress}
        '';
      };
    };

    services.coredns = {
      enable = true;
      config = ''
        .:9053 {
          errors
          log
          cache
          forward . 127.0.0.1:9055 127.0.0.1:9057 127.0.0.1:9058 {
            policy sequential
            health_check 5s 
          }
        }

        #.:9054 {
        #  forward . https://cloudflare-dns.com/dns-query {
        #    health_check 5s 
        #  }
        #} 
        
        .:9055 {
          forward . tls://1.1.1.1 tls://1.0.0.1 {
            tls_servername cloudflare-dns.com
            health_check 5s 
          }
        }

        #.:9056 {
        #  forward . https://dns.google/dns-query {
        #    health_check 5s 
        #  } 
        #}
        
        .:9057 {
          forward . tls://8.8.8.8 tls://8.8.4.4 {
            tls_servername dns.google
            health_check 5s 
          }
        }

        # fallbacks to provider's dns servers :(
        .:9058 {
          forward . dns://217.10.32.5 dns://217.10.35.5
        }

        home.:9053 {
          hosts {
            192.168.0.20 photos.home 
          }

          cache
        }
      '';
    };

    services.stubby = {
      enable = true;
      settings = pkgs.stubby.passthru.settingsExample // {
        listen_addresses = [ "127.0.0.1@8053" ];
        upstream_recursive_servers = [
          {
            address_data = "1.1.1.1";
            tls_auth_name = "cloudflare-dns.com";
            tls_pubkey_pinset = [
              {
                digest = "sha256";
                value = "SPfg6FluPIlUc6a5h313BDCxQYNGX+THTy7ig5X3+VA=";
              }
            ];
          }

          {
            address_data = "1.0.0.1";
            tls_auth_name = "cloudflare-dns.com";
            tls_pubkey_pinset = [
              {
                digest = "sha256";
                value = "SPfg6FluPIlUc6a5h313BDCxQYNGX+THTy7ig5X3+VA=";
              }
            ];
          }
        ];
      };
    };
  };
}
