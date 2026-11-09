{ config, lib, ... }:

let
  hostname = config.networking.hostName;
  secrets = import ../../secrets;
  filterProxyUsersForHost = import ../../common/filter-proxy-users.nix { inherit lib; };
  selectProxyUser = import ../../common/select-proxy-user.nix;
  users = filterProxyUsersForHost hostname secrets.singBoxUsers;
  reverseUser = selectProxyUser hostname secrets.singBoxUsers;
in
{
  imports = [
    ../../common/tailscale-client.nix
    ../../roles
  ];

  ###
  # Roles
  ###
  roles.hardened.enable = true;

  roles.observability.agent.enable = true;

  roles.xray.metrics.enable = true;

  # Sole xray mode on buyan: the public server. Public SNIs/ports are
  # unchanged; the reverseBridge adds the two Buyan-initiated links to
  # Veles's relay RAW/xHTTP portal (relay SNIs, not the retired direct SNIs).
  roles.xray.server = {
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
          sni = "ghcr.io";
        };
        grpc = {
          enable = true;
          sni = "update.googleapis.com";
        };
        xhttp = {
          enable = true;
          sni = "dl.google.com";
        };
      };
      hysteria2.enable = false; # keep supported server mode
    };
    reverseBridge = {
      enable = true;
      addresses = [
        {
          host = "veles";
          address = secrets.ip.veles.address;
        }
        {
          host = "stribog";
          address = secrets.ip.stribog.address;
        }
      ];
      user = reverseUser;
      reality = {
        publicKey = secrets.xray.reality.publicKey;
        shortId = builtins.head secrets.xray.reality.shortIds;
      };
      vless = {
        raw.serverName = "api.oneme.ru";
        xhttp.serverName = "onlymir.ru";
        # xhttp.path defaults to "/vl-xhttp"
      };
    };
  };

  # Public TCP/2053 reaches the existing SNI-router listener on TCP/443
  # via a host-firewall PREROUTING REDIRECT.
  roles.sni-router.redirectPorts = [ 2053 ];

}
