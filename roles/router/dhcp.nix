{ config, pkgs, lib, ... }:
with lib;

let
  cfg = config.roles.dhcp;
in {
  options.roles.dhcp = {
    enable = mkEnableOption "Enable DHCP Server";
    openFirewall = mkEnableOption "Open Firewall";
    hostMAC = mkOption { type = types.str; description = "Host's MAC Address"; };
    hostIP = mkOption { type = types.str; description = "Host's IP Address"; };
    gatewayIP = mkOption { type = types.str; description = "Gateway's IP Address"; };
  };

  config = mkIf cfg.enable {
    networking.firewall.allowedUDPPorts = optionals cfg.openFirewall [ 67 ];

    services.dnsmasq = {
      enable = true;

      settings = {
        dhcp-range="192.168.0.21,192.168.0.150,12h";
        dhcp-host="${cfg.hostMAC},${cfg.hostIP}";
      };

      extraConfig = ''
        dhcp-option=option:router,${cfg.gatewayIP}
        dhcp-option=option:dns-server,${cfg.hostIP}
        dhcp-option=252,"http://192.168.0.20/proxy.pac"
        dhcp-sequential-ip
      '';
    };
  };
}