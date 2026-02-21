{
  ...
}:

let
  hostname = "veles";
  domainName = "uspenskiy.su";
in
{
  imports = [
    ../../common/hardened.nix
    ../../common/server.nix
    ../../hardware/vm.nix
    ../../roles/letsencrypt.nix
    ../../roles/network/stream-forwarder.nix
    ../../roles/n8n.nix
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

  services.openssh.settings = {
    PermitRootLogin = "no";
    PasswordAuthentication = false;
  };

  ###
  # Roles
  ###
  roles.hardened.enable = true;

  roles.letsencrypt = {
    enable = true;
    domains = [ domainName ];
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

  roles.n8n = {
    enable = true;
    hostname = domainName;
  };

  system.stateVersion = "25.11";
}
