{ config, pkgs, lib, ... }:

let 
  hostname = "nixpi";
in {
  imports = [
    ../../common/server.nix
    ../../common/zeroconf.nix
    ../../roles/share.nix
    ../../roles/media.nix
    ../../roles/torrent.nix
    ../../roles/router/dns.nix
    ../../roles/router/dhcp.nix
    ../../roles/router/nginx.nix
    ../../roles/shadowsocks/client.nix
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

  roles.dhcp = {
    enable = true;
    openFirewall = true;
    hostMAC = "DC:A6:32:07:25:C1";
    hostIP = "192.168.0.20";
    gatewayIP = "192.168.0.1";
  };

  roles.shadowsocks-client = {
    enable = true;
    host = "gw.uspenskiy.su";
    openFirewall = true;
  };

  roles.home-nginx = {
    enable = true;
    openFirewall = true;
    ip = "192.168.0.20";
  };

  roles.zeroconf.enable = true;

  services.journald = {
    storage = "volatile";
  };

  system.stateVersion = "24.05";
}