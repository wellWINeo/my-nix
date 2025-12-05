{ ... }:

let
  hostname = "veles";
  ifname = "";
in
{
  imports = [
    ../../common/hardened.nix
    ../../common/server.nix
    ../../hardware/vm.nix

  ];

  # disk layout
  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/NIXOS";
      fsType = "ext4";
    };
  };

  swapDevices = [ { device = "/dev/disk-by-label/SWAP"; } ];

  # network
  networking = {
    hostName = hostname;
    useDHCP = true;
    nameservers = [ "1.1.1.1" ];
    firewall.enable = true;

    interfaces."${ifname}" = {
      ipv4.addresses = [
        {
          address = "93.183.127.202";
          prefixLength = 24;
        }
      ];
    };

    defaultGateway = {
      address = "";
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
}
