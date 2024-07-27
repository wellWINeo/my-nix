{ config, pkgs, lib, ... }:
with lib;

let 
  cfg = config.roles.shadowsocks-client;
in {
  disabledModules = [ "services/networking/shadowsocks.nix" ];

  imports = [ ../../common/shadowsocks.nix ];

  options.roles.shadowsocks-client = {
    enable = mkEnableOption "Enable ShadowSocks client";
    host = mkOption { type = types.str; description = "Host for v2ray plugin"; };
  };

  config = mkIf cfg.enable {
    services.shadowsocks = {
      enable = true;
      isServer = false;
      package = pkgs.shadowsocks-rust;
      port = 8388;
      plugin = "${pkgs.shadowsocks-v2ray-plugin}/bin/v2ray-plugin";
      mode = "tcp_and_udp";
      localAddress = cfg.host; # actually it's `server` property, not local
      fastOpen = true;
      passwordFile = "/etc/nixos/secrets/shadowsocksPassword";
      encryptionMethod = "aes-256-gcm";
      pluginOpts = "tls;host=${cfg.host};path=/fckrkn";
      extraConfig = {
        nameserver = "1.1.1.1";
      };
    };
  };
}