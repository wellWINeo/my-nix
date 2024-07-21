{ config, pkgs, lib, ... }:

let
  hostname = "mokosh";
in {
  imports = [ ../../hardware/vm.nix ];

  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/NIXOS";
      fsType = "ext4";
    };
  };

  swapDevices = [ { device = "/dev/disk/by-label/SWAP"; } ];

  networking = {
    hostName = hostname;
    useDHCP = false;
    nameservers = [ "1.1.1.1" ];

    interfaces.ens3 = {
      ipv4.addresses = [ 
        { address = "93.183.127.202"; prefixLength = 24; } 
      ];
    };

    defaultGateway = {
      address = "93.183.127.1";
      interface = "ens3";
    };
  };

  services.openssh.enable = true;

  system.stateVersion = "24.05";
}
