{ lib, ... }:

let
  hostname = "stribog";
  ifname = "net0";
  secrets = import ../../secrets;
  ip = secrets.ip.stribog;
  filterProxyUsersForHost = import ../../common/filter-proxy-users.nix { inherit lib; };
  selectProxyUser = import ../../common/select-proxy-user.nix;
  users = filterProxyUsersForHost hostname secrets.singBoxUsers;
  reverseUser = selectProxyUser "buyan" users;
  relayUser = selectProxyUser "veles" secrets.singBoxUsers;
in
{
  imports = [
    ../../common/cache.nix
    ../../common/hardened.nix
    ../../common/server.nix
    ../../hardware/vm.nix
    ../../roles
  ];

  boot.loader.grub.device = "/dev/vda";
  boot.initrd.systemd.enable = false;
  fileSystems."/" = {
    device = "/dev/vda2";
    fsType = "ext4";
  };
  zramSwap.enable = true;

  networking = {
    hostName = hostname;
    useDHCP = false;
    dhcpcd.enable = false;
    usePredictableInterfaceNames = lib.mkForce true;
    nameservers = [ "1.1.1.1" ];
    firewall.enable = true;
    interfaces.${ifname} = {
      ipv4.addresses = [
        {
          address = ip.address;
          prefixLength = 32;
        }
      ];
      ipv4.routes = [
        {
          address = ip.gateway;
          prefixLength = 32;
        }
      ];
      ipv6.addresses = [
        {
          address = ip.address6;
          prefixLength = 48;
        }
      ];
      ipv6.routes = [
        {
          address = ip.gateway6;
          prefixLength = 128;
        }
      ];
    };
    defaultGateway = {
      address = ip.gateway;
      interface = ifname;
    };
    defaultGateway6 = {
      address = ip.gateway6;
      interface = ifname;
    };
  };
  services.udev.extraRules = ''
    ATTR{address}=="${ip.macAddress}", NAME="${ifname}"
  '';

  services.qemuGuest.enable = true;
  services.openssh.settings = {
    PermitRootLogin = "prohibit-password";
    PasswordAuthentication = false;
  };
  users.users.root.openssh.authorizedKeys.keys = [ secrets.sshKey ];

  roles.hardened.enable = true;
  roles.observability.agent.enable = true;
  roles.xray.metrics.enable = true;
  roles.xray.relay = {
    enable = true;
    ingress = {
      inherit users;
      reality = {
        privateKeyFile = "/etc/nixos/secrets/xray-reality-private-key";
        shortIds = secrets.xray.reality.shortIds;
      };
      vless = {
        raw = {
          enable = true;
          sni = "api.oneme.ru";
        };
        grpc = {
          enable = true;
          sni = "avatars.mds.yandex.net";
        };
        xhttp = {
          enable = true;
          sni = "onlymir.ru";
        };
      };
      hysteria2 = {
        enable = true;
        port = 443;
        sni = "turn.webrtc.yandex.net";
        certFile = "/etc/nixos/secrets/hysteria-veles-cert";
        keyFile = "/etc/nixos/secrets/hysteria-veles-key";
        masquerade = {
          type = "proxy";
          url = "https://turn.webrtc.yandex.net";
        };
      };
    };
    egress = {
      via = "reverse";
      reverse.user = reverseUser;
      forward = {
        user = relayUser;
        server = secrets.ip.buyan.address;
        backupPort = 2053;
        reality = {
          publicKey = secrets.xray.reality.publicKey;
          shortId = builtins.head secrets.xray.reality.shortIds;
          fingerprint = "randomized";
        };
        vless = {
          raw = {
            enable = true;
            serverName = "ghcr.io";
          };
          grpc = {
            enable = true;
            serverName = "update.googleapis.com";
          };
          xhttp = {
            enable = true;
            serverName = "dl.google.com";
          };
        };
      };
    };
  };

  roles.sni-router.redirectPorts = [ 2053 ];
  roles.stream-forwarder = {
    enable = true;
    forwards = [
      {
        listenAddress = "0.0.0.0:8443";
        targetAddress = "${secrets.ip.mokosh.address}:443";
      }
    ];
  };
  services.tailscale = {
    enable = true;
    openFirewall = true;
    authKeyFile = "/etc/nixos/secrets/tailscale-auth-key";
    extraUpFlags = [
      "--login-server=https://headscale.uspenskiy.tech"
      "--accept-dns=false"
    ];
    extraSetFlags = [ "--accept-dns=false" ];
  };
  systemd.services.tailscaled-autoconnect.serviceConfig = {
    Restart = "on-failure";
    RestartSec = "30s";
  };

  # Preserve the version set by nixos-infect on the existing installation.
  system.stateVersion = "23.11";
}
