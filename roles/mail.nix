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
          proxy.trusted-networks = [
            "127.0.0.0/8"
            "::1"
            "10.0.0.0/8"
          ];

          listener = {
            "smtp" = {
              bind = "127.0.0.1:10025";
              protocol = "smtp";
            };

            "submissions" = {
              bind = "127.0.0.1:10465";
              protocol = "smtp";
              tls.implicit = false;
            };

            "imap" = {
              bind = "127.0.0.1:10993";
              protocol = "imap";
              tls.implicit = false;
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

        store."rocksdb" = {
          type = "rocksdb";
          path = "/var/lib/stalwart";
        };

        directory."internal" = {
          type = "internal";
          store = "rocksdb";
        };

        tracer."stdout" = {
          type = "stdout";
          level = "info";
          ansi = false;
          enable = true;
        };

        authentication."fallback-admin" = {
          user = "admin";
          secret = "%{file:/etc/nixos/secrets/stalwart_admin_passwd}%";
        };
      };
    };

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
      '';
    };
  };
}
