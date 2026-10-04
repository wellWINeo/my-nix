{ lib, ... }:

let
  hostname = "stribog";
  secrets = import ../../secrets;
  filterProxyUsersForHost = import ../../common/filter-proxy-users.nix { inherit lib; };
  users = filterProxyUsersForHost hostname secrets.singBoxUsers;
in
{
  imports = [
    ../../common/cache.nix
    ../../common/hardened.nix
    ../../common/server.nix
    ../../hardware/vm.nix
    ../../roles
    ./disk.nix
  ];

  boot = {
    # ipv6 on twc has poor performance
    kernel.sysctl."net.ipv6.conf.all.disable_ipv6" = 1;
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

  roles.xray = {
    enable = true;
    server = {
      enable = true;
      users = users;
      reality.privateKeyFile = "/etc/nixos/secrets/xray-reality-private-key";
      vlessTcp = {
        enable = true;
        sni = "ghcr.io";
      };
      vlessGrpc = {
        enable = true;
        sni = "update.googleapis.com";
      };
      vlessXhttp = {
        enable = true;
        sni = "dl.google.com";
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

  system.stateVersion = "26.05";
}
