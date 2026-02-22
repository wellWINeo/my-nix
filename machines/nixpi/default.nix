{ ... }:

let
  hostname = "nixpi";
  ifname = "end0";
  ip = "192.168.0.20";
  gatewayIP = "192.168.0.1";
  secrets = import ../../secrets;
in
{
  imports = [
    ../../common/server.nix
    ../../common/zeroconf.nix
    ../../common/btrfs-balance.nix
    ../../roles/share.nix
    ../../roles/media.nix
    ../../roles/torrent.nix
    ../../roles/router/dns.nix
    ../../roles/router/dhcp.nix
    ../../roles/router/nginx.nix
    ../../roles/network/shadowsocks/client.nix
    ../../roles/network/wireguard/wireguard-client.nix
    ../../roles/photos.nix
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
    ipAddress = ip;
  };

  roles.dhcp = {
    enable = true;
    openFirewall = true;
    hostMAC = "DC:A6:32:07:25:C1";
    hostIP = ip;
    gatewayIP = gatewayIP;
  };

  roles.shadowsocks-client = {
    enable = true;
    host = "gw.uspenskiy.su";
    openFirewall = true;
  };

  roles.wireguard-client = {
    enable = true;
    ip = "10.20.0.25";
    endpoint = "93.183.127.202:51820";
    serverPubKey = secrets.wireguard.mokosh-pubkey;
  };

  roles.home-nginx = {
    enable = true;
    ip = ip;
  };

  roles.photos = {
    enable = true;
    storagePath = "/mnt/storage/Photos";
  };

  roles.zeroconf.enable = true;

  services.journald = {
    storage = "volatile";
  };

  system.stateVersion = "25.11";
}
