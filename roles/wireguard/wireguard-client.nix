{ config, pkgs, lib, ... }:
with lib;
with types;

let
  cfg = config.roles.wireguard-client;
in {
  options.roles.wireguard-client = {
    enable = mkEnableOption "Enable WireGuard Client";
    ip = mkOption {
      type = str;
      description = "Client's IP address";
    };
    endpoint = mkOption { 
      type = str; 
      description = "Server's <ip>:<port>";
    };
    serverPubKey = mkOption {
      type = str;
      description = "Server's public key";
    };
  };

  config = mkIf cfg.enable {
    networking.wireguard.interfaces.wg-client = {
      ips = [ "${cfg.ip}/32" ];

      privateKeyFile = "/etc/nixos/secrets/wireguard-nixpi.privkey";

      peers = [
        {
          publicKey = cfg.serverPubKey;
          allowedIPs = [ "10.20.0.1/24" ];
          endpoint = cfg.endpoint;
        }
      ];
    };
  };
}