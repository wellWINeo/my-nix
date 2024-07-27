{ config, pkgs, lib, ... }:
with lib;

let 
  cfg = config.roles.shadowsocks-server;
in {
  disabledModules = [ "services/networking/shadowsocks.nix" ];

  imports = [ ../../common/shadowsocks.nix ];

  options.roles.shadowsocks-server.enable = mkEnableOption "Enable ShadowSocks server";

  config = mkIf cfg.enable {
    services.shadowsocks = {
      enable = true;
      package = pkgs.shadowsocks-rust;
      port = 8388;
      plugin = "${pkgs.shadowsocks-v2ray-plugin}/bin/v2ray-plugin";
      mode = "tcp_and_udp";
      localAddress = [ "127.0.0.1" ];
      fastOpen = true;
      passwordFile = "/etc/nixos/secrets/passwordFile";
      encryptionMethod = "aes-256-gcm";
      pluginOpts = "server";
      extraConfig = {
        nameserver = "1.1.1.1";
      };
    };
  };
}