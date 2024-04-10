# configuration Raspberry Pi 4 Model B Rev 1.1 (2 GB RAM)

{ config, pkgs, lib, ... }:

{
  boot = {
    kernelPackages = pkgs.linuxKernel.packages.linux_rpi4;
    initrd.availableKernelModules = [ "xhci_pci" "usbhid" "usb_storage" ];
    loader = {
      grub.enable = false;
      generic-extlinux-compatible.enable = true;
    };
  };

  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/NIXOS_SD";
      fsType = "ext4";
      options = [ "noatime" ];
    };

    "/mnt/storage" = {
      device = "/dev/disk/by-label/STORAGE";
      fsType = "btrfs";
    };
  };

  hardware.enableRedistributableFirmware = true;
}
