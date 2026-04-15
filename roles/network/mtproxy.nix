# roles/network/mtproxy.nix
#
# Telegram MTProxy via telemt (Rust implementation).
# Runs in fake-TLS (ee) mode behind sni-router.
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.roles.mtproxy;

  configFile = pkgs.writeText "telemt.toml" (
    ''
      [general]
      use_middle_proxy = ${boolToString cfg.useMiddleProxy}
      log_level = "normal"

      [general.modes]
      classic = false
      secure = false
      tls = true

      [server]
      port = ${toString cfg.port}
      proxy_protocol = true

      [[server.listeners]]
      ip = "127.0.0.1"

      [censorship]
      tls_domain = "${cfg.tls.domain}"
      mask = true
      tls_emulation = true
      tls_front_dir = "/var/lib/telemt/tlsfront"

      [access.users]
      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: secret: ''${name} = "${secret}"'') cfg.users
      )}
    ''
    + lib.optionalString (cfg.upstream != null) ''

      [[upstreams]]
      type = "socks5"
      address = "${cfg.upstream}"
    ''
  );
in
{
  options.roles.mtproxy = {
    enable = mkEnableOption "Telegram MTProxy via telemt";

    useMiddleProxy = mkOption {
      type = types.bool;
      default = true;
      description = "Use middle proxy for outgoing connections";
    };

    tls.domain = mkOption {
      type = types.str;
      description = "Domain for fake-TLS SNI (used for TLS emulation and sni-router entry)";
      example = "google.com";
    };

    port = mkOption {
      type = types.port;
      default = 9100;
      description = "Local port telemt listens on (behind sni-router)";
    };

    users = mkOption {
      type = types.attrsOf types.str;
      description = "Map of username to 32-char hex secret";
      example = {
        alice = "00000000000000000000000000000001";
      };
    };

    upstream = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "SOCKS5 upstream address (host:port). Null = direct via middle proxies.";
      example = "127.0.0.1:1080";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.users != { };
        message = "roles.mtproxy.users must contain at least one user";
      }
    ];

    # Requires sni-router.nix to be imported (directly or via roles/network/xray).
    roles.sni-router.entries = [
      {
        sni = cfg.tls.domain;
        backend = "127.0.0.1:${toString cfg.port}";
      }
    ];

    systemd.services.telemt = {
      description = "Telegram MTProxy (telemt)";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /var/lib/telemt/tlsfront";
        ExecStart = "${pkgs.telemt}/bin/telemt ${configFile}";
        Restart = "on-failure";
        DynamicUser = true;
        StateDirectory = "telemt";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        RestrictAddressFamilies = "AF_INET AF_INET6";
      };
    };
  };
}
