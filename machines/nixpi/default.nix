{ config, pkgs, lib, ... }:

let 
  hostname = "nixpi";
in {
  imports = [ 
    ../../roles/share.nix
    ../../roles/media.nix
    ../../roles/torrent.nix
    ../../hardware/rpi4.nix
  ];

  environment.systemPackages = with pkgs; [
    gnumake
    pinentry-curses
  ];

  programs.gnupg.agent = {
		enable = true;

    # available in nixos-unstable
		#pinentryPackage = pkgs.pinentry-curses;

    # for nixos 23.11
    pinentryFlavor = "curses";
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

  services.openssh.enable = true;

  system.stateVersion = "23.11";
}