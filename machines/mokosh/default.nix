{ ... }:

let
  hostname = "mokosh";
  domainName = "uspenskiy.su";
  ifname = "ens3";
in
{
  imports = [
    ../../common/hardened.nix
    ../../common/server.nix
    ../../hardware/vm.nix
    ../../roles/personal-website.nix
    ../../roles/letsencrypt.nix
    ../../roles/wireguard/wireguard-router.nix
    ../../roles/vault.nix
    ../../roles/shadowsocks/server.nix
    ../../roles/communication/mail.nix
    ../../roles/communication/dav.nix
    ../../roles/reading/calibre.nix
    ../../roles/reading/rss.nix
    ../../roles/blog.nix
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
        {
          address = "93.183.127.202";
          prefixLength = 24;
        }
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
  users.groups.web.members = [
    "nginx"
    "acme"
  ]; # setup common group to gran nginx access to acme's certs

  roles.hardened.enable = true;

  roles.mail = {
    enable = false; # temporarly disable due to lack binary cache
    sslCertificatesDirectory = "/var/lib/acme/${domainName}";
    hostname = "mail-test.${domainName}";
  };

  roles.personelWebsite = {
    enable = true;
    domain = domainName;
  };

  roles.letsencrypt = {
    enable = true;
    domains = [
      domainName
      "uspenskiy.tech"
    ];
  };

  roles.wireguardRouter = {
    enable = true;
    externalIf = ifname;
    clients = [
      # MacBook Pro
      {
        pubKey = "QiTggD0EDepZDbUU1KW+M6l2NWHe67DS8jje5EKDGhU=";
        ip = "10.20.0.10";
        isInternal = true;
      }

      # iPhone
      {
        pubKey = "6JnxIyp7ggP5tfz7j2JFvQKIM2QvQR2FRbaPfHb6tGs=";
        ip = "10.20.0.15";
        isInternal = true;
      }

      # iPad
      {
        pubKey = "VPX34DmeV81hlY6CTz2nTyUxiUDgsrJYTsuMEkI5WEI=";
        ip = "10.20.0.20";
        isInternal = true;
      }

      # nixpi
      {
        pubKey = "rVBQwSoTqIDjv1AYOdw2rgKKcMNPBuCEcdDdqjpsIiw=";
        ip = "10.20.0.25";
        isInternal = true;
      }

      # desktop
      {
        pubKey = "6ifvdl8YdBUgGUp17lm/RlcNXfUpH84WKkH2zgnLSH8=";
        ip = "10.20.0.30";
        isInternal = true;
      }

      ###
      # Limited vpn net goes below
      ###

      # grandma
      {
        pubKey = "X1PgQ9CZHS4zW7RCeqD9g8s/7gCQWk5tzTgO1uQ84BI=";
        ip = "10.30.0.10";
        isInternal = false;
      }

      {
        pubKey = "9tKr4z0Em7MADdmdCrhBJ/lR73BfrhcPtrdZgihrHS0=";
        ip = "10.30.0.11";
        isInternal = false;
      }

      # Philips 55 
      {
        pubKey = "Me6/vN0sbqunnSb4YwKWV7gs98AlRCWG/vBZfOtSOSA=";
        ip = "10.30.0.15";
        isInternal = false;
      }

      # TLC 32
      {
        pubKey = "pPHnwKwS4auDJ3t8OMHJxBGnpbYDjyg/tdpD4yElcSc=";
        ip = "10.30.0.20";
        isInternal = false;
      }
    ];
  };

  roles.vault = {
    enable = true;
    baseDomain = domainName;
    enableWeb = true;
  };

  roles.shadowsocks-server = {
    enable = true;
    openFirewall = false;
    baseDomain = domainName;
    enableWeb = true;
  };

  roles.calibre = {
    enable = true;
    baseDomain = domainName;
  };

  roles.rss = {
    enable = true;
    baseDomain = domainName;
  };

  roles.blog = {
    enable = true;
    baseDomain = domainName;
  };

  roles.dav = {
    enable = true;
    baseDomain = domainName;
  };


  system.stateVersion = "25.05";
}
