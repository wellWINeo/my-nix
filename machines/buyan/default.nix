{ lib, ... }:

let
  hostname = "buyan";
  ifname = "ens3";
  ip = (import ../../secrets).ip.buyan;
  secrets = import ../../secrets;
  filterProxyUsersForHost = import ../../common/filter-proxy-users.nix { inherit lib; };
  users = filterProxyUsersForHost hostname secrets.singBoxUsers;
in
{
  imports = [
    ../../common/hardened.nix
    ../../common/server.nix
    ../../hardware/vm.nix
    ../../roles/network/xray
  ];

  boot.loader.grub.device = "/dev/vda";

  # disk layout
  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/NIXROOT";
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

  roles.xray = {
    enable = true;
    server = {
      enable = true;
      users = users;
      reality.privateKeyFile = "/etc/nixos/secrets/xray-reality-private-key";
      vlessTcp = {
        enable = true;
        sni = "ghcr.io";
      };
      vlessGrpc = {
        enable = true;
        sni = "update.googleapis.com";
      };
      vlessXhttp = {
        enable = true;
        sni = "dl.google.com";
      };
    };
  };

  system.stateVersion = "25.11";
}
