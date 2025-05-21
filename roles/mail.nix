{ config, lib, ... }:
with lib;

let
  cfg = config.roles.mail;
in
{
  options.roles.mail = {
    enable = mkEnableOption "Enable mail server with stalwart";
    domain = mkOption {
      type = types.string;
      description = "Mail domain";
    };
  };

  config = mkIf cfg.enable {
    services.stalwart-mail = {
      enable = true;
      openFirewall = false;
      settings = {
        server = {
          hostname = cfg.domain;
          tls.enable = false;
          proxy.trusted-networks = [
            "127.0.0.0/8"
            "::1"
            "10.0.0.0/8"
          ];

          listener = {
            smtp = {
              bind = "127.0.0.1:10025";
              protocol = "smtp";
              proxy-protocol = true;
            };

            submission = {
              bind = "127.0.0.1:10587";
              protocol = "smtp";
              tls.implicit = false;
              proxy-protocol = true;
            };

            submissions = {
              bind = "127.0.0.1:10465";
              protocol = "smtp";
              tls.implicit = false;
              proxy-protocol = true;
            };

            imap = {
              bind = "127.0.0.1:10993";
              protocol = "imap";
              tls.implicit = false;
              proxy-protocol = true;
            };
          };
        };

        storage = {
          data = "rocksdb";
          fts = "rocksdb";
          blob = "rocksdb";
          lookup = "rocksdb";
          directory = "internal";
        };

        store.rocksdb = {
          type = "rocksdb";
          path = "/var/lib/stalwart";
        };

        directory.internal = {
          type = "internal";
          store = "rocksdb";
        };

        tracer.journal = {
          type = "journal";
          level = "info";
          enable = true;
        };

        tracer."stdout" = {
          type = "stdout";
          level = "info";
          ansi = false;
          enable = true;
        };

        management = {
          bind = [ "127.0.0.1:10080" ];
          protocol = [ "http" ];
        };

        authentication."fallback-admin" = {
          user = "admin";
          secret = "%{file:/etc/nixos/secrets/stalwart_admin_passwd}%";
        };
      };
    };

    networking.firewall.allowedTCPPorts = [
      25
      465
      587
      993
    ];

    services.nginx = {
      streamConfig = ''
        # Proxy SMTP
        server {
          listen 25 proxy_protocol;
          proxy_pass 127.0.0.1:10025;
          proxy_protocol on;
        }

        # Proxy IMAPS
        server {
          listen 993 proxy_protocol;
          proxy_pass 127.0.0.1:10993;
          proxy_protocol on;
        }

        # Proxy SMTPS
        server {
          listen 465 proxy_protocol;
          proxy_pass 127.0.0.1:10465;
          proxy_protocol on;
        }

        # Proxy Submission (STARTTLS) 
        server {
          listen 587 proxy_protocol;
          proxy_pass 127.0.0.1:10587;
          proxy_protocol on;
        }
      '';

      virtualHosts = {
        ${cfg.domain} = {
          forceSSL = true;
          enableACME = true;
          locations."/" = {
            proxyPass = "http://127.0.0.1:10080";
          };
        };
      };
    };
  };
}
