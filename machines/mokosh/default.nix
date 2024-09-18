{ config, pkgs, lib, ... }:

let
  hostname = "mokosh";
  domainName = "uspenskiy.su";
  secrets = import ../../secrets;
  ifname = "ens3";
in {
  imports = [ 
    ../../common/server.nix
    ../../hardware/vm.nix
    ../../roles/personal-website.nix
    ../../roles/letsencrypt.nix
    ../../roles/wireguard/wireguard-router.nix
    ../../roles/vault.nix
    ../../roles/obsidian-livesync.nix
    ../../roles/shadowsocks/server.nix
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

    interfaces."${ifname}" = {
      ipv4.addresses = [ 
        { address = "93.183.127.202"; prefixLength = 24; } 
      ];
    };

    defaultGateway = {
      address = "93.183.127.1";
      interface = ifname;
    };
  };

  services.openssh.settings = {
    PermitRootLogin = "no";
    PasswordAuthentication = false;
  };


  ###
  # Roles
  ###
  users.groups.web.members = [ "nginx" "acme" ]; # setup common group to gran nginx access to acme's certs

  roles.personelWebsite = {
    enable = true;
    domain = domainName;
  };

  roles.letsencrypt = {
    enable = true;
    domain = domainName;
  };

  roles.wireguardRouter = {
    enable = true;
    externalIf = ifname;
    clients = [
      # MacBook Pro
      {
        pubKey = "QiTggD0EDepZDbUU1KW+M6l2NWHe67DS8jje5EKDGhU=";
        ip = "10.20.0.10";
      }

      # iPhone
      {
        pubKey = "6JnxIyp7ggP5tfz7j2JFvQKIM2QvQR2FRbaPfHb6tGs=";
        ip = "10.20.0.15";
      }

      # iPad
      {
        pubKey = "VPX34DmeV81hlY6CTz2nTyUxiUDgsrJYTsuMEkI5WEI=";
        ip = "10.20.0.20";
      }

      # nixpi
      {
        pubKey = "rVBQwSoTqIDjv1AYOdw2rgKKcMNPBuCEcdDdqjpsIiw=";
        ip = "10.20.0.25";
      }
    ];
  };

  roles.vault = {
    enable = true;
    baseDomain = domainName;
  };

  roles.shadowsocks-server = {
    enable = true;
    openFirewall = false;
  };

  roles.obsidian-livesync = {
    enable = true;
    domain = domainName;
    adminPassword = secrets.couchdbAdminPassword;
  };

  system.stateVersion = "24.05";
}
