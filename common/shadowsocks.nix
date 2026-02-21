{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.shadowsocks;
  opts = {
    server = cfg.localAddress;
    server_port = cfg.port;
    method = cfg.encryptionMethod;
    mode = cfg.mode;
    user = "nobody";
    fast_open = cfg.fastOpen;
  }
  // optionalAttrs (cfg.plugin != null) {
    plugin = cfg.plugin;
    plugin_opts = cfg.pluginOpts;
  }
  // optionalAttrs (cfg.password != null) {
    password = cfg.password;
  }
  // cfg.extraConfig;

  configFile = pkgs.writeText "shadowsocks.json" (builtins.toJSON opts);

  isLibev = pkg: getName pkg == "shadowsocks-libev";
  getTitle = pkg: if isLibev pkg then "libev" else "rust";
  getPostfix = isServer: if isServer then "server" else "local";
in
{

  ###### interface

  options = {

    services.shadowsocks = {

      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to run shadowsocks server.
        '';
      };

      package = mkPackageOption [ pkgs.shadowsocks-libev pkgs.shadowsocks-rust ] "shadowsocks" { };

      localAddress = mkOption {
        type = types.oneOf [
          types.str
          (types.listOf types.str)
        ];
        default = [
          "[::0]"
          "0.0.0.0"
        ];
        description = ''
          Local addresses to which the server binds.
        '';
      };

      port = mkOption {
        type = types.port;
        default = 8388;
        description = ''
          Port which the server uses.
        '';
      };

      password = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Password for connecting clients.
        '';
      };

      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Password file with a password for connecting clients.
        '';
      };

      mode = mkOption {
        type = types.enum [
          "tcp_only"
          "tcp_and_udp"
          "udp_only"
        ];
        default = "tcp_and_udp";
        description = ''
          Relay protocols.
        '';
      };

      fastOpen = mkOption {
        type = types.bool;
        default = true;
        description = ''
          use TCP fast-open
        '';
      };

      encryptionMethod = mkOption {
        type = types.str;
        default = "chacha20-ietf-poly1305";
        description = ''
          Encryption method. See <https://github.com/shadowsocks/shadowsocks-org/wiki/AEAD-Ciphers>.
        '';
      };

      plugin = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = literalExpression ''"''${pkgs.shadowsocks-v2ray-plugin}/bin/v2ray-plugin"'';
        description = ''
          SIP003 plugin for shadowsocks
        '';
      };

      pluginOpts = mkOption {
        type = types.str;
        default = "";
        example = "server;host=example.com";
        description = ''
          Options to pass to the plugin if one was specified
        '';
      };

      isServer = mkOption {
        type = types.bool;
        default = true;
        description = "Run as server or local";
      };

      extraConfig = mkOption {
        type = types.attrs;
        default = { };
        example = {
          nameserver = "8.8.8.8";
        };
        description = ''
          Additional configuration for shadowsocks that is not covered by the
          provided options. The provided attrset will be serialized to JSON and
          has to contain valid shadowsocks options. Unfortunately most
          additional options are undocumented but it's easy to find out what is
          available by looking into the source code of
          <https://github.com/shadowsocks/shadowsocks-libev/blob/master/src/jconf.c>
        '';
      };
    };

  };

  ###### implementation

  config = mkIf cfg.enable {
    assertions = [
      {
        # xor, make sure either password or passwordFile be set.
        # shadowsocks-libev not support plain/none encryption method
        # which indicated that password must set.
        assertion =
          let
            noPasswd = cfg.password == null;
            noPasswdFile = cfg.passwordFile == null;
          in
          (noPasswd && !noPasswdFile) || (!noPasswd && noPasswdFile);
        message = "Option `password` or `passwordFile` must be set and cannot be set simultaneously";
      }
    ];

    systemd.services."shadowsocks-${getTitle cfg.package}-${getPostfix cfg.isServer}" = {
      description = "shadowsocks-${getTitle cfg.package} Daemon";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      path = [
        cfg.package
      ]
      ++ optional (cfg.plugin != null) cfg.plugin
      ++ optional (cfg.passwordFile != null) pkgs.jq;
      serviceConfig.PrivateTmp = true;
      script = ''
        ${optionalString (cfg.passwordFile != null) ''
          cat ${configFile} | jq --arg password "$(cat "${cfg.passwordFile}")" '. + { password: $password }' > /tmp/shadowsocks.json
        ''}
        exec ss${if isLibev cfg.package then "-" else ""}${getPostfix cfg.isServer} -c ${
          if cfg.passwordFile != null then "/tmp/shadowsocks.json" else configFile
        }
      '';
    };
  };
}
