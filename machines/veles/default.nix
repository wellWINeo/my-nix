{
  lib,
  ...
}:

let
  hostname = "veles";
  secrets = import ../../secrets;
  mokoshIp = secrets.ip.mokosh.address;
  filterProxyUsersForHost = import ../../common/filter-proxy-users.nix { inherit lib; };
  selectProxyUser = import ../../common/select-proxy-user.nix;
  users = filterProxyUsersForHost hostname secrets.singBoxUsers;
  # Reverse-link identity (Buyan-initiated bridge), selected from the same
  # host-filtered list the relay advertises to ordinary clients.
  reverseUser = selectProxyUser "buyan" users;
  relayUser = selectProxyUser hostname secrets.singBoxUsers;
in
{
  imports = [
    ../../common/cache.nix
    ../../common/hardened.nix
    ../../common/server.nix
    ../../hardware/vm.nix
    ../../roles
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

  roles.observability.agent.enable = true;

  roles.xray.metrics.enable = true;

  # Sole xray mode on veles: the relay portal. Ordinary clients keep the
  # existing relay SNIs/ports; egress goes out through Buyan via the
  # Buyan-initiated reverse links. The full forward target tree stays
  # configured (inert) for a manual rollback via egress.via = "forward".
  roles.xray.relay = {
    enable = true;
    ingress = {
      users = users;
      reality = {
        privateKeyFile = "/etc/nixos/secrets/xray-reality-private-key";
        shortIds = secrets.xray.reality.shortIds;
      };
      vless = {
        raw = {
          enable = true;
          sni = "api.oneme.ru";
        };
        grpc = {
          enable = true;
          sni = "avatars.mds.yandex.net";
        };
        xhttp = {
          enable = true;
          sni = "onlymir.ru"; # xhttp.path defaults to "/vl-xhttp"
        };
        # CDN-fronted loopback ingress (Timeweb edge -> HTTPS origin -> Nginx
        # -> 127.0.0.1:9013). Decryption is injected at runtime from the
        # human-installed credential file, and the guarded startup fails
        # closed until the operator installs a valid value. Activating this
        # CDN path is a separately approved deployment gate with its own
        # go/no-go tests (docs/veles-timeweb-cdn-deployment.md); building or
        # merging this configuration never deploys it.
        cdnXhttp = {
          enable = true;
          originDomain = "sunny-bee-on-the-flower.net.by";
          path = "/vl-cdn";
          decryptionFile = "/etc/nixos/secrets/vlessenc-decryption-key";
        };
      };
      hysteria2 = {
        enable = true;
        port = 443;
        sni = "turn.webrtc.yandex.net";
        certFile = "/etc/nixos/secrets/hysteria-veles-cert";
        keyFile = "/etc/nixos/secrets/hysteria-veles-key";
        masquerade = {
          type = "proxy";
          url = "https://turn.webrtc.yandex.net";
        };
      };
    };
    egress = {
      via = "reverse";
      reverse.user = reverseUser;
      forward = {
        user = relayUser;
        server = secrets.ip.buyan.address;
        # Paired forward candidates: primary TCP/443 + backup TCP/2053 (the
        # REDIRECTed SNI-router port on buyan). Inert while via = "reverse".
        backupPort = 2053;
        reality = {
          publicKey = secrets.xray.reality.publicKey;
          shortId = builtins.head secrets.xray.reality.shortIds;
          fingerprint = "randomized"; # preserved, not newly recommended
        };
        vless = {
          raw = {
            enable = true;
            serverName = "ghcr.io";
          };
          grpc = {
            enable = true;
            serverName = "update.googleapis.com";
          };
          xhttp = {
            enable = true;
            serverName = "dl.google.com";
          };
        };
        hysteria2 = {
          enable = false;
          serverName = "bing.com";
          insecure = true;
          certificateFingerprint = null;
          port = 36712;
        };
      };
    };
  };

  # Public TCP/2053 reaches the existing SNI-router listener on TCP/443
  # via a host-firewall PREROUTING REDIRECT.
  roles.sni-router.redirectPorts = [ 2053 ];

  services.tailscale = {
    enable = true;
    openFirewall = true;
    authKeyFile = "/etc/nixos/secrets/tailscale-auth-key";
    extraUpFlags = [
      "--login-server=https://headscale.uspenskiy.tech"
      "--accept-dns=false"
    ];
    extraSetFlags = [ "--accept-dns=false" ];
  };

  systemd.services.tailscaled-autoconnect.serviceConfig = {
    Restart = "on-failure";
    RestartSec = "30s";
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

  system.stateVersion = "26.05";
}
