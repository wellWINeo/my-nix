{ ifname }:

{ ... }:

let
  hostname = "mokosh";
in
{
  imports = [
    ../../common/cache.nix
    ../../common/hardened.nix
    ../../common/server.nix
    ../../images/do-generic
  ];

  # disk layout
  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/NIXOS";
      fsType = "ext4";
    };
  };

  swapDevices = [ { device = "/.swapfile"; } ];

  # network
  networking = {
    hostName = hostname;
    nameservers = [ "1.1.1.1" ];
    firewall.enable = true;
  };

  services.openssh.settings = {
    PermitRootLogin = "no";
    PasswordAuthentication = false;
  };

  system.stateVersion = "26.05";
}
