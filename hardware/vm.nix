# Configuration for Virtual Machine
{
  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };

    initrd.availableKernelModules = [ "sd_mod" "sr_mod" ];
  };

  virtualisation.hypervGuest.enable = true;
}