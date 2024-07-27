{ config, pkgs, lib, ... }:

let 
  hostname = "nixpi";
in {
  imports = [
    ../../common/server.nix
    ../../roles/share.nix
    ../../roles/media.nix
    ../../roles/torrent.nix
    ../../roles/router/dns.nix
    ../../hardware/rpi4.nix
  ];

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
    interval = "weekly";
    fileSystems = [
      "/mnt/storage"
      "/swap"
    ];
  };

  networking = {
    hostName = hostname;
    wireless.enable = false;    
    firewall = {
      enable = true;
      allowPing = true;
    };
  };

  roles.share = {
    hostname = hostname;
    enable = true;
    enableTimeMachine = true;
  };

  roles.media.enable = true;
  roles.torrent.enable = true;
  roles.dns = {
    enable = true;
    openFirewall = true;
    useLocalDNS = true;
  };

  services.journald = {
    storage = "volatile";
  };

  system.stateVersion = "24.05";
}