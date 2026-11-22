{ ifname }:

{ lib, ... }:

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

  nix.settings = {
    # Keep this after the shared Yandex cache.
    substituters = lib.mkOrder 2000 [ "https://d3ktcuzmslp03i.cloudfront.net" ];
    trusted-public-keys = [
      "nix-anysync-cache:8ig/2DyERXghDDOwhDJcjZaxx+A77HwREpQfSIh1oZc="
    ];
  };

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
