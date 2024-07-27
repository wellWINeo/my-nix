{ config, pkgs, lib, ... }:
with lib;

let 
  cfg = config.roles.shadowsocks-client;
  port = 1080;
in {
  disabledModules = [ "services/networking/shadowsocks.nix" ];

  imports = [ ../../common/shadowsocks.nix ];

  options.roles.shadowsocks-client = {
    enable = mkEnableOption "Enable ShadowSocks client";
    host = mkOption { type = types.str; description = "Host for v2ray plugin"; };
    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open firewall";
    };
  };

  config = mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = optionals cfg.openFirewall [ port ];

    services.shadowsocks = {
      enable = true;
      isServer = false;
      package = pkgs.shadowsocks-rust;
      port = 443;
      plugin = "${pkgs.shadowsocks-v2ray-plugin}/bin/v2ray-plugin";
      mode = "tcp_and_udp";
      localAddress = cfg.host; # actually it's `server` property, not local
      fastOpen = true;
      passwordFile = "/etc/nixos/secrets/shadowsocksPassword";
      encryptionMethod = "aes-256-gcm";
      pluginOpts = "tls;host=${cfg.host};path=/fckrkn";
      extraConfig = {
        nameserver = "1.1.1.1";
        local_address = "0.0.0.0";
        local_port = port;
      };
    };
  };
}