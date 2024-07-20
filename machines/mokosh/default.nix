{ config, pkgs, lib, ... }:

let
  hostname = "mokosh";
in {
  imports = [ ../../hardware/vm.nix ];

  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "ext4";
    };

    "/boot" = {
      device = "/dev/disk/by-label/boot";
      fsType = "vfat";
      options = [ "fmask=0777" "dmask=0777" ];
    };
  };

  swapDevices = [ { device = "/dev/disk/by-label/swap"; } ];

  networking = {
    hostName = hostname;
    useDHCP = true;
  };

  services.openssh.enable = true;

  system.stateVersion = "24.05";
}
