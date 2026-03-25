{
  ...
}:

let
  hostname = "veles";
  mokoshIp = (import ../../secrets).ip.mokosh.address;
in
{
  imports = [
    ../../common/hardened.nix
    ../../common/server.nix
    ../../hardware/vm.nix
    ../../roles/network/stream-forwarder.nix
    ../../roles/network/xray/server.nix
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

  roles.xray-server = {
    enable = true;
    reality.privateKeyFile = "/etc/nixos/secrets/xray-reality-private-key";
    vlessTcp = {
      enable = true;
      sni = "api.oneme.ru";
    };
    vlessGrpc = {
      enable = true;
      sni = "avatars.mds.yandex.net";
    };
    vlessXhttp = {
      enable = true;
      sni = "onlymir.ru";
    };
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
