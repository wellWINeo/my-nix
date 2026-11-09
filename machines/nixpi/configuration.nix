{
  ifname,
  ip,
  gatewayIP,
}:

{ ... }:

let
  hostname = "nixpi";
in
{
  imports = [
    ../../common/cache.nix
    ../../common/server.nix
    ../../common/zeroconf.nix
    ../../common/btrfs-balance.nix
    ../../hardware/rpi4.nix
  ];

  boot.kernel.sysctl = {
    "fs.inotify.max_user_watches" = 524288;
  };

  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/NIXOS_SD";
      fsType = "ext4";
      options = [ "noatime" ];
    };

    "/mnt/storage" = {
      device = "/dev/disk/by-label/STORAGE";
      options = [ "subvol=storage" ];
      fsType = "btrfs";
    };

    "/swap" = {
      device = "/dev/disk/by-label/STORAGE";
      options = [ "subvol=swap" ];
      fsType = "btrfs";
    };
  };

  swapDevices = [ { device = "/swap/swapfile"; } ];

  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [
      "/mnt/storage"
      "/swap"
    ];
  };

  services.btrfs.balance = {
    enable = true;
    interval = "weekly";
    fileSystems = [ "/mnt/storage" ];
  };

  networking = {
    hostName = hostname;
    wireless.enable = false;
    useDHCP = false;
    firewall = {
      enable = true;
      allowPing = true;
    };

    interfaces."${ifname}" = {
      ipv4.addresses = [
        {
          address = ip;
          prefixLength = 24;
        }
      ];
    };

    defaultGateway = {
      address = gatewayIP;
      interface = ifname;
    };
  };

  services.journald = {
    storage = "volatile";
  };

  system.stateVersion = "26.05";
}
