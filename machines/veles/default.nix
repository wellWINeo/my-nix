{
  lib,
  ...
}:

let
  hostname = "veles";
  secrets = import ../../secrets;
  mokoshIp = secrets.ip.mokosh.address;
  filterProxyUsersForHost = import ../../common/filter-proxy-users.nix { inherit lib; };
  users = filterProxyUsersForHost hostname secrets.singBoxUsers;
in
{
  imports = [
    ../../common/hardened.nix
    ../../common/server.nix
    ../../hardware/vm.nix
    ../../roles/network/stream-forwarder.nix
    ../../roles/network/mtproxy.nix
    ../../roles/network/xray
  ];

  boot = {
    loader.grub.device = "/dev/sda";

    # ipv6 on twc has poor performance
    kernel.sysctl."net.ipv6.conf.all.disable_ipv6" = 1;
  };

  # disk layout
  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/NIXROOT";
      fsType = "ext4";
    };
  };

  swapDevices = [
    {
      device = "/.swapfile";
      size = 2 * 1024; # 2GiB
    }
  ];

  # network
  networking = {
    hostName = hostname;
    useDHCP = true;
    nameservers = [
      "1.1.1.1"
      "1.0.0.1"
    ];
    firewall.enable = true;
  };

  services.qemuGuest.enable = true;
  services.spice-vdagentd.enable = true;

  services.openssh.settings = {
    PermitRootLogin = "no";
    PasswordAuthentication = false;
  };

  ###
  # Roles
  ###
  roles.hardened.enable = true;

  roles.xray = {
    enable = true;
    server = {
      enable = true;
      users = users;
      reality.privateKeyFile = "/etc/nixos/secrets/xray-reality-private-key";
      vlessTcp.enable = true;
      vlessGrpc = {
        enable = true;
        sni = "avatars.mds.yandex.net";
      };
      vlessXhttp = {
        enable = true;
        sni = "onlymir.ru";
      };
    };
    relay = {
      enable = true;
      users = users;
      socks.enable = true;

      vlessTcp.sni = "api.oneme.ru";
      vlessGrpc.sni = "grpc.google.com";
      vlessXhttp.sni = "www.cloudflare.com";
      user = builtins.head secrets.singBoxUsers;
      target = {
        server = secrets.ip.buyan.address;
        reality = {
          publicKey = secrets.xray.reality.publicKey;
          shortId = builtins.head (secrets.xray.reality.shortIds);
        };
        vlessTcp = {
          enable = true;
          serverName = "ghcr.io";
        };
        vlessGrpc = {
          enable = true;
          serverName = "update.googleapis.com";
        };
        vlessXhttp = {
          enable = true;
          serverName = "dl.google.com";
        };
      };
    };
  };

  roles.mtproxy = {
    enable = true;
    useMiddleProxy = false;
    tls.domain = "api.ok.ru";
    port = 9100;
    upstream = "127.0.0.1:1080";
    users = secrets.mtproxy.users;
  };

  roles.stream-forwarder = {
    enable = true;
    forwards = [
      {
        listenAddress = "0.0.0.0:8443";
        targetAddress = "${mokoshIp}:443";
      }
    ];
  };

  system.stateVersion = "25.11";
}
