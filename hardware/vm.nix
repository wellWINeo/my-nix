# Configuration for Virtual Machine

{
  boot = {
    loader.grub.enable = true;

    initrd.availableKernelModules = [
      "ata_piix"
      "uhci_hcd"
      "virtio_pci"
      "virtio_scsi"
      "sd_mod"
      "sr_mod"
      "virtio_blk"
    ];
  };

  virtualisation.hypervGuest.enable = true;
}
