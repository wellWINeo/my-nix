{ ... }:

let
  hostname = "buyan";
  ifname = "ens3";
  ip = (import ../../secrets).ip.buyan;
in
{
  imports = [
    ../../common/hardened.nix
    ../../common/server.nix
    ../../hardware/vm.nix
    ../../roles/network/xray/server.nix
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

  roles.xray-server = {
    enable = true;
    reality.privateKeyFile = "/etc/nixos/secrets/buyan-xray-reality.privkey";
    vlessTcp = {
      enable = true;
      sni = "ghcr.io";
    };
    vlessGrpc = {
      enable = true;
      sni = "ghcr.io";
    };
    vlessXhttp = {
      enable = true;
      sni = "ghcr.io";
    };
  };

  system.stateVersion = "25.11";
}
