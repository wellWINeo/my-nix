# Generic DigitalOcean-bootable NixOS profile.
#
# Scope: hardware/boot/network only. No users, tooling, or roles — those come
# from other modules (e.g. users/o__ni, common/server.nix). Importing this
# module exposes `system.build.digitalOceanImage` (a qcow2 builder) and wires
# the runtime bits a droplet needs: virtio drivers, growpart on the root
# partition, and cloud-init for networking from DO metadata.
#
# Constraint: root filesystem must be ext4 (autoResize uses online ext4 resize).

{ modulesPath, lib, ... }:

{
  imports = [
    "${modulesPath}/virtualisation/digital-ocean-image.nix"
  ];

  boot = {
    growPartition = true;

    initrd.availableKernelModules = [
      "virtio_pci"
      "virtio_scsi"
      "virtio_blk"
      "sd_mod"
    ];
  };

  networking = {
    useDHCP = false;
    hostName = lib.mkDefault "";
  };

  services.cloud-init = {
    enable = true;
    network.enable = true;
    settings.datasource_list = [
      "DigitalOcean"
      "None"
    ];
  };
}
