{ config, pkgs, lib, ... }:

let
  hostname = "mokosh";
  domainName = "uspenskiy.su";
  secrets = import ../../secrets;
in {
  imports = [ 
    ../../hardware/vm.nix
    ../../roles/personal-website.nix
    ../../roles/letsencrypt.nix
  ];

  # disk layout
  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/NIXOS";
      fsType = "ext4";
    };
  };

  swapDevices = [ { device = "/dev/disk/by-label/SWAP"; } ];

  # network
  networking = {
    hostName = hostname;
    useDHCP = false;
    nameservers = [ "1.1.1.1" ];
    firewall.enable = true;

    interfaces.ens3 = {
      ipv4.addresses = [ 
        { address = "93.183.127.202"; prefixLength = 24; } 
      ];
    };

    defaultGateway = {
      address = "93.183.127.1";
      interface = "ens3";
    };
  };

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
    };
  };


  ###
  # Roles
  ###
  roles.personelWebsite = {
    enable = true;
    domain = domainName;
  };

  roles.letsencrypt = {
    enable = true;
    cloudflareApiKey = secrets.cloudflareApiKey;
    domain = domainName;
  };

  system.stateVersion = "24.05";
}
