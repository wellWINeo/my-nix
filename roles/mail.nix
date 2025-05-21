{ config, lib, ... }:
with lib;

let
  cfg = config.roles.mail;
in
{
  options.roles.mail = {
    enable = mkEnableOption "Enable mail server with stalwart";

    sslCertificatesDirectory = mkOption {
      type = types.path;
      description = "Path to ssl certificates for nginx";
    };

    hostname = mkOption {
      type = types.string;
      description = "Mail hostname";
    };
  };

  config = mkIf cfg.enable {
    services.stalwart-mail = {
      enable = true;
      openFirewall = false;
      settings = {
        server = {
          hostname = cfg.hostname;
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

        store.rocksdb = {
          type = "rocksdb";
          path = "/var/lib/stalwart-mail";
        };

        directory.internal = {
          type = "internal";
          store = "rocksdb";
        };

        storage = {
          data = "rocksdb";
          fts = "rocksdb";
          blob = "rocksdb";
          lookup = "rocksdb";
          directory = "internal";
        };

        tracer.stdout = {
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
          secret = "%{file:/etc/nixos/secrets/stalwart-admin-password}%";
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
        ${cfg.hostname} = {
          forceSSL = true;
          enableACME = false;
          sslCertificate = "${cfg.sslCertificatesDirectory}/fullchain.pem";
          sslCertificateKey = "${cfg.sslCertificatesDirectory}/key.pem";
          locations."/" = {
            proxyPass = "http://127.0.0.1:10080";
          };
        };
      };
    };
  };
}
