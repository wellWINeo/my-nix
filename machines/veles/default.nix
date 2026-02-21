{ ... }:

let
  hostname = "veles";
in
{
  imports = [
    ../../common/hardened.nix
    ../../common/server.nix
    ../../hardware/vm.nix
  ];

  boot.loader.grub.device = "/dev/sda";

  # disk layout
  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/NIXOS";
      fsType = "ext4";
    };
  };

  swapDevices = [
    {
      device = "/.swapfile";
      size = 4 * 1024; # 4GiB
    }
  ];

  # network
  networking = {
    hostName = hostname;
    useDHCP = true;
    nameservers = [
      "1.1.1.1"
      "1.0.0.1"
    ];
    firewall.enable = true;
  };

  services.openssh.settings = {
    PermitRootLogin = "no";
    PasswordAuthentication = false;
  };

  ###
  # Roles
  ###
  roles.hardened.enable = true;

  system.stateVersion = "25.11";
}
