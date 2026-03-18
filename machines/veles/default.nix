{
  ...
}:

let
  hostname = "veles";
in
{
  imports = [
    ../../common/hardened.nix
    ../../common/server.nix
    ../../hardware/vm.nix
    ../../roles/network/stream-forwarder.nix
    ../../roles/network/xray/server.nix
  ];

  boot.loader.grub.device = "/dev/sda";

  # disk layout
  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/NIXOS";
      fsType = "ext4";
    };
  };

  swapDevices = [
    {
      device = "/.swapfile";
      size = 4 * 1024; # 4GiB
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
    reality = {
      privateKeyFile = "/etc/nixos/secrets/veles-xray-reality.privkey";
      fakeSni = "api.oneme.ru";
    };
    vlessWs.enable = true;
    vlessGrpc.enable = true;
    vlessXhttp.enable = true;
  };

  roles.stream-forwarder = {
    enable = true;
    forwards = [
      {
        listenAddress = "0.0.0.0:8443";
        targetAddress = "93.183.127.202:443";
      }
    ];
  };

  system.stateVersion = "25.11";
}
