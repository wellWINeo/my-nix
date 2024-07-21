# Configuration for Virtual Machine
{
  boot = {
    loader.grub = {
      enable = true;
      device = "/dev/vda";
    };

    initrd.availableKernelModules = [ 
      "ata_piix"
      "uhci_hcd"
      "virtio_pci"
      "sr_mod"
      "virtio_blk"
    ];
  };

  virtualisation.hypervGuest.enable = true;
}