{ config, pkgs, lib, ... }:
with lib;
with types;

let
  cfg = config.roles.wireguardRouter;
  port = 51820;
  toPeer = peer: {
    publicKey = peer.pubKey;
    allowedIPs = [ "${peer.ip}/32" ];
  };
  clientType = submodule {
    options = {
      pubKey = mkOption { type = str; description = "Public key"; };
      ip = mkOption { type = str; description = "Client's IP"; };
    };
  };
in {
  options.roles.wireguardRouter = {
    enable = mkEnableOption "Enable WireGuard Router";
    externalIf = mkOption { 
      type = str; 
      description = "External interface name"; 
    };
    openFirewall = mkOption {
      type = bool;
      default = true;
      description = "Open FireWall";
    };
    privateKey = mkOption {
      type = str;
      description = "WireGuard router's private key";
    };
    clients = mkOption {
      type = listOf clientType;
      default = [];
      description = "WireGuard clients";
    };
  };

  config = mkIf cfg.enable {
    networking = {
      nat = {
        enable = true;
        externalInterface = cfg.externalIf;
        internalInterfaces = [ "wg0" ];
      };

      firewall.allowedUDPPorts = optionals cfg.openFirewall [ port ];

      wireguard.interfaces = {
        wg0 = {
          ips = [ "10.20.0.1/24" ];
          listenPort = port;

          postSetup = ''
            ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s 10.20.0.0/24 -o ${cfg.externalIf} -j MASQUERADE
          '';

          postShutdown = ''
            ${pkgs.iptables}/bin/iptables -t nat -D POSTROUTING -s 10.20.0.0/24 -o ${cfg.externalIf} -j MASQUERADE
          '';

          privateKey = cfg.privateKey;

          peers = map toPeer cfg.clients;
        };
      };
    };
  };
}