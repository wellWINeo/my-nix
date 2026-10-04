{ lib, ... }:

let
  hostname = "nixpi";
  ifname = "end0";
  ip = "192.168.0.20";
  gatewayIP = "192.168.0.1";
  secrets = import ../../secrets;
  mokoshIp = secrets.ip.mokosh.address;
  selectProxyUser = import ../../common/select-proxy-user.nix;
  nixpiXrayUser = selectProxyUser hostname secrets.singBoxUsers;
in
{
  imports = [
    ../../common/cache.nix
    ../../common/server.nix
    ../../common/zeroconf.nix
    ../../common/btrfs-balance.nix
    ../../hardware/rpi4.nix
    ../../roles
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
    metrics.enable = true;
  };

  roles.observability.agent.enable = true;

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
    endpoint = "${mokoshIp}:51820";
    serverPubKey = secrets.wireguard.mokosh-pubkey;
  };

  services.tailscale = {
    enable = true;
    openFirewall = true;
    disableUpstreamLogging = true;
    extraSetFlags = [ "--accept-dns=false" ];
  };

  roles.xray = {
    client = {
      enable = true;
      ingress = {
        socks.port = 1081;
        http.enable = true;
        openFirewall = true;
        tunnels = [
          {
            listen = "127.0.0.1:5053";
            target = "1.1.1.1:853";
          }
        ];
      };

      egress = {
        server = secrets.ip.veles.address;
        user = nixpiXrayUser;
        backupPort = 2053;
        reality = {
          publicKey = secrets.xray.reality.publicKey;
          shortId = builtins.head secrets.xray.reality.shortIds;
          fingerprint = "randomized";
        };
        vless = {
          raw = {
            enable = true;
            serverName = "api.oneme.ru";
          };
          grpc = {
            enable = true;
            serverName = "avatars.mds.yandex.net";
          };
          xhttp = {
            enable = true;
            serverName = "onlymir.ru";
          };
        };
      };
    };
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

  system.stateVersion = "26.05";
}
