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

        lookup.default.hostname = cfg.hostname;

        server = {
          hostname = cfg.hostname;
          tls = {
            enable = true;
            implicit = true;
          };

          listener = {
            smtp = {
              bind = "0.0.0.0:25";
              protocol = "smtp";
            };

            submission = {
              bind = "0.0.0.0:587";
              protocol = "smtp";
              tls.enable = true;
            };

            submissions = {
              bind = "0.0.0.0:465";
              protocol = "smtp";
              tls.enable = true;
            };

            imap = {
              bind = "0.0.0.0:993";
              protocol = "imap";
              tls.enable = true;
            };

            management = {
              bind = [ "127.0.0.1:10080" ];
              protocol = "http";
              tls.enable = false;
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

        authentication."fallback-admin" = {
          user = "admin";
          secret = "%{file:/etc/nixos/secrets/stalwart-admin-password}%";
        };

        certificate.default = {
          cert = "%{file:${cfg.sslCertificatesDirectory}/fullchain.pem}%";
          private-key = "%{file:${cfg.sslCertificatesDirectory}/key.pem}%";
        };

        webadmin.auto-update = false;

        signature.ed25519 = {
          private-key = "%{file:/etc/nixos/secrets/dkim.privkey}%";
          domain = cfg.hostname;
          selector = "default";
          headers = [
            "From"
            "To"
            "Cc"
            "Date"
            "Subject"
            "Message-ID"
            "Organization"
            "MIME-Version"
            "Content-Type"
            "In-Reply-To"
            "References"
            "List-Id"
            "User-Agent"
            "Thread-Topic"
            "Thread-Index"
          ];
          algorithm = "ed25519-sha256";
          canonicalization = "relaxed/relaxed";
          set-body-length = false;
          report = false;
        };

        auth = {
          dkim = {
            verify = "relaxed";
            sign = [
              {
                "if" = "listener != 'smtp'";
                "then" = "'ed25519'";
              }
              { "else" = false; }
            ];
          };

          spf.verify = {
            ehlo = [
              {
                "if" = "listener = 'smtp'";
                "then" = "relaxed";
              }
              { "else" = "disable"; }
            ];
            mail-from = [
              {
                "if" = "listener = 'smtp'";
                "then" = "relaxed";
              }
              { "else" = "disable"; }
            ];
          };

          arc = {
            seal = "ed25519";
            verify = "relaxed";
          };

          dmarc = {
            verify = [
              {
                "if" = "listener = 'smtp'";
                "then" = "relaxed";
              }
              { "else" = "disable"; }
            ];
          };
        };
      };

    };

    users.users.stalwart-mail.extraGroups = [ "web" ];

    networking.firewall.allowedTCPPorts = [
      25
      465
      587
      993
    ];

    services.nginx = {
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
