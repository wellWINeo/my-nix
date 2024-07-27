{ config, pkgs, lib, ... }:
with lib;

let 
  cfg = config.roles.shadowsocks-server;
in {
  disabledModules = [ "services/networking/shadowsocks.nix" ];

  imports = [ ../../common/shadowsocks.nix ];

  options.roles.shadowsocks-server.enable = mkEnableOption "Enable ShadowSocks Server";

  config = mkIf cfg.enable {
    services.shadowsocks = {
      enable = true;
      isServer = true;
      package = pkgs.shadowsocks-rust;
      port = 443;
      plugin = "${pkgs.shadowsocks-v2ray-plugin}/bin/v2ray-plugin";
      mode = "tcp_and_udp";
      localAddress = "0.0.0.0";
      fastOpen = true;
      passwordFile = "/etc/nixos/secrets/shadowsocksPassword";
      encryptionMethod = "aes-256-gcm";
      pluginOpts = "server";
      extraConfig = {
        nameserver = "1.1.1.1";
      };
    };
  };
}