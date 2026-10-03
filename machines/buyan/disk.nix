# Host-owned Disko layout: BIOS/GRUB (GPT with EF02) install via nixos-anywhere.
# Runtime mounts keep the same ext4 labels the previous fileSystems block used,
# overridden onto the Disko-generated entries via mkForce.
{ lib, ... }:

let
  rootLabel = "NIXROOT";
  storeLabel = "NIXSTORE";
in
{
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/vda";
    content = {
      type = "gpt";
      partitions = {
        boot = {
          size = "1M";
          type = "EF02"; # BIOS boot partition for GRUB
          priority = 1; # must precede the data partitions
        };
        root = {
          size = "8G";
          content = {
            type = "filesystem";
            format = "ext4";
            extraArgs = [
              "-L"
              rootLabel
            ];
            mountpoint = "/";
          };
        };
        nix = {
          size = "100%"; # remaining space; 16 GiB min-disk preflight in provision wrapper
          content = {
            type = "filesystem";
            format = "ext4";
            extraArgs = [
              "-L"
              storeLabel
            ];
            mountpoint = "/nix";
          };
        };
      };
    };
  };

  # Disko would emit mount option "defaults"; force the exact mount options
  # the previous fileSystems block produced so runtime behavior is unchanged.
  fileSystems = {
    "/" = {
      device = lib.mkForce "/dev/disk/by-label/${rootLabel}";
      options = lib.mkForce [ "x-initrd.mount" ];
    };
    "/nix" = {
      device = lib.mkForce "/dev/disk/by-label/${storeLabel}";
      options = lib.mkForce [ "x-initrd.mount" ];
    };
  };
}
