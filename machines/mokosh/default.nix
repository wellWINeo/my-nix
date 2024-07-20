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

  networking.hostname = hostname;

  services.openssh.enable = true;

  isoImage = {
    iso = true;
    grub = {
      device = "nodev";
      efiSupport = true;
      enable = true;
    };
  };
}
