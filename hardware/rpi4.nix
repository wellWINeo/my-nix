# configuration Raspberry Pi 4 Model B Rev 1.1 (2 GB RAM)

{ ... }:

{
  boot = {
    # disabled due to deprecation in NixOS 26.05
    # kernelPackages = pkgs.linuxKernel.packages.linux_rpi4;
    initrd.availableKernelModules = [
      "xhci_pci"
      "usbhid"
      "usb_storage"
    ];
    loader = {
      grub.enable = false;
      generic-extlinux-compatible.enable = true;
    };
  };

  hardware.enableRedistributableFirmware = true;
}
