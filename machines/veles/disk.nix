# Host-owned Disko layout: BIOS/GRUB (GPT with EF02) install via nixos-anywhere.
# Runtime mounts keep the same ext4 label the previous fileSystems block used,
# overridden onto the Disko-generated entry via mkForce.
{ lib, ... }:

let
  rootLabel = "NIXROOT";
in
{
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/sda";
    content = {
      type = "gpt";
      partitions = {
        boot = {
          size = "1M";
          type = "EF02"; # BIOS boot partition for GRUB
          priority = 1; # must precede the data partition
        };
        root = {
          size = "100%";
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
      };
    };
  };

  # Disko would emit mount option "defaults"; force the exact mount options
  # the previous fileSystems block produced so runtime behavior is unchanged.
  fileSystems."/" = {
    device = lib.mkForce "/dev/disk/by-label/${rootLabel}";
    options = lib.mkForce [ "x-initrd.mount" ];
  };
}
