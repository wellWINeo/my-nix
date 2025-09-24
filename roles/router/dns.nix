{
  config,
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
      firewall.allowedUDPPorts = optionals cfg.openFirewall [ 53 ];
      nameservers = optionals cfg.useLocalDNS [ "127.0.0.1" ];
    };

    services.coredns = {
      enable = true;
      config = ''
        . {
          errors
          log
          cache {
            success 5000 3600 30
            denial 2500 1800 30
            prefetch 10 1m 10%
            serve_stale 1h
          }

          forward . 127.0.0.1:9055 127.0.0.1:9057 127.0.0.1:9058 {
            policy sequential
            health_check 5s
            max_fails 2

            # added in v1.12.1
            # failfast_all_unhealthy_upstreams
          }
        }

        home {
          hosts {
            ${cfg.ipAddress} photos.home 
          }

          cache
        }

        ###
        # upstreams
        ###

        # need to use external plugin:
        # https://github.com/v-byte-cpu/coredns-https
        #.:9054 {
        #  forward . https://cloudflare-dns.com/dns-query {
        #    health_check 5s 
        #  }
        #} 

        .:9055 {
          forward . tls://1.1.1.1 tls://1.0.0.1 {
            tls_servername cloudflare-dns.com
            health_check 5s
            max_fails 2
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
            max_fails 2
          }
        }

        # fallbacks to provider's dns servers :(
        .:9058 {
          forward . dns://217.10.32.5 dns://217.10.35.5 {
            max_fails 3
          }
        }
      '';
    };
  };
}
