{ config, pkgs, lib, ... }:
with lib;
with types;
with builtins;

let
  cfg = config.roles.wireguardRouter;
  port = 51820;
  toPeer = peer: {
    publicKey = peer.pubKey;
    allowedIPs = [ "${peer.ip}/32" ];
  };
  isInternal = 
    isInternal: 
      peer: 
        peer.isInternal == isInternal;
  clientType = submodule {
    options = {
      pubKey = mkOption { type = str; description = "Public key"; };
      ip = mkOption { type = str; description = "Client's IP"; };
      isInternal = mkOption { type = bool; description = "Is internal VPN peer"; };
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
        internalInterfaces = [ "wg0" "wg-public" ];
      };

      firewall = {
        allowedUDPPorts = optionals cfg.openFirewall [ port (port + 1) ];
        extraCommands = ''
          ${pkgs.iptables}/bin/iptables -I FORWARD -s 10.20.0.0/24 -d 10.30.0.0/24 -j DROP
          ${pkgs.iptables}/bin/iptables -I FORWARD -s 10.30.0.0/24 -d 10.20.0.0/24 -j DROP
        '';
        extraStopCommands = ''
          ${pkgs.iptables}/bin/iptables -C FORWARD -s 10.20.0.0/24 -d 10.30.0.0/24 -j DROP 2>/dev/null && \
            ${pkgs.iptables}/bin/iptables -D FORWARD -s 10.20.0.0/24 -d 10.30.0.0/24 -j DROP

          ${pkgs.iptables}/bin/iptables -C FORWARD -s 10.30.0.0/24 -d 10.20.0.0/24 -j DROP 2>/dev/null && \
            ${pkgs.iptables}/bin/iptables -D FORWARD -s 10.30.0.0/24 -d 10.20.0.0/24 -j DROP
        '';
      };

      wireguard.interfaces = {
        # internal
        wg0 = {
          ips = [ "10.20.0.1/24" ];
          listenPort = port;

          postSetup = ''
            ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s 10.20.0.0/24 -o ${cfg.externalIf} -j MASQUERADE
          '';

          postShutdown = ''
            ${pkgs.iptables}/bin/iptables -t nat -D POSTROUTING -s 10.20.0.0/24 -o ${cfg.externalIf} -j MASQUERADE
          '';

          privateKeyFile = "/etc/nixos/secrets/wireguard-mokosh.privkey";

          peers = map toPeer (filter (client: client.isInternal) cfg.clients);
        };

        # public
        wg-public = {
          ips = [ "10.30.0.1/24" ];
          listenPort = port + 1;
                    
          postSetup = ''
            ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s 10.30.0.0/24 -o ${cfg.externalIf} -j MASQUERADE
          '';

          postShutdown = ''
            ${pkgs.iptables}/bin/iptables -t nat -D POSTROUTING -s 10.30.0.0/24 -o ${cfg.externalIf} -j MASQUERADE
          '';

          privateKeyFile = "/etc/nixos/secrets/wireguard-public-mokosh.privkey";

          peers = map toPeer (filter (client: !client.isInternal) cfg.clients);
        };
      };
    };
  };
}