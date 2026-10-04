{ lib, ... }:

let
  hostname = "buyan";
  ifname = "ens3";
  ip = (import ../../secrets).ip.buyan;
  secrets = import ../../secrets;
  filterProxyUsersForHost = import ../../common/filter-proxy-users.nix { inherit lib; };
  selectProxyUser = import ../../common/select-proxy-user.nix;
  users = filterProxyUsersForHost hostname secrets.singBoxUsers;
  reverseUser = selectProxyUser hostname secrets.singBoxUsers;
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

  # disk layout
  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/NIXROOT";
      fsType = "ext4";
    };
    "/nix" = {
      device = "/dev/disk/by-label/NIXSTORE";
      fsType = "ext4";
    };
  };

  swapDevices = [
    {
      device = "/.swapfile";
      size = 2 * 1024; # 2GiB
    }
  ];

  # network
  networking = {
    hostName = hostname;
    useDHCP = false;
    nameservers = [ "1.1.1.1" ];
    firewall.enable = true;

    interfaces."${ifname}" = {
      ipv4.addresses = [
        {
          address = ip.address;
          prefixLength = 24;
        }
      ];
    };

    defaultGateway = {
      address = ip.gateway;
      interface = ifname;
    };
  };

  services.openssh.settings = {
    PermitRootLogin = "no";
    PasswordAuthentication = false;
  };

  ###
  # Roles
  ###
  roles.hardened.enable = true;

  roles.observability.agent.enable = true;

  roles.xray.metrics.enable = true;

  # Sole xray mode on buyan: the public server. Public SNIs/ports are
  # unchanged; the reverseBridge adds the two Buyan-initiated links to
  # Veles's relay RAW/xHTTP portal (relay SNIs, not the retired direct SNIs).
  roles.xray.server = {
    enable = true;
    ingress = {
      users = users;
      reality = {
        privateKeyFile = "/etc/nixos/secrets/xray-reality-private-key";
        shortIds = secrets.xray.reality.shortIds;
      };
      vless = {
        raw = {
          enable = true;
          sni = "ghcr.io";
        };
        grpc = {
          enable = true;
          sni = "update.googleapis.com";
        };
        xhttp = {
          enable = true;
          sni = "dl.google.com";
        };
      };
      hysteria2.enable = false; # keep supported server mode
    };
    reverseBridge = {
      enable = true;
      address = secrets.ip.veles.address;
      user = reverseUser;
      reality = {
        publicKey = secrets.xray.reality.publicKey;
        shortId = builtins.head secrets.xray.reality.shortIds;
      };
      vless = {
        raw.serverName = "api.oneme.ru";
        xhttp.serverName = "onlymir.ru";
        # xhttp.path defaults to "/vl-xhttp"
      };
    };
  };

  # Public TCP/2053 reaches the existing SNI-router listener on TCP/443
  # via a host-firewall PREROUTING REDIRECT.
  roles.sni-router.redirectPorts = [ 2053 ];

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

  system.stateVersion = "26.05";
}
