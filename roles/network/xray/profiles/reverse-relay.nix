{ config, lib, ... }:
let
  hostname = config.networking.hostName;
  secrets = import ../../../../secrets;
  filterProxyUsersForHost = import ../../../../common/filter-proxy-users.nix { inherit lib; };
  selectProxyUser = import ../../../../common/select-proxy-user.nix;
  users = filterProxyUsersForHost hostname secrets.singBoxUsers;
  reverseUser = selectProxyUser "buyan" users;
  relayUser = selectProxyUser hostname secrets.singBoxUsers;
in
{
  roles.xray.metrics.enable = true;
  roles.xray.relay = {
    enable = true;
    ingress = {
      inherit users;
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
          sni = "onlymir.ru";
        };
      };
      hysteria2 = {
        enable = true;
        port = 443;
        sni = "turn.webrtc.yandex.net";
        certFile = "/etc/nixos/secrets/hysteria-${hostname}-cert";
        keyFile = "/etc/nixos/secrets/hysteria-${hostname}-key";
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
        backupPort = 2053;
        reality = {
          publicKey = secrets.xray.reality.publicKey;
          shortId = builtins.head secrets.xray.reality.shortIds;
          fingerprint = "randomized";
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
      };
    };
  };

  roles.sni-router.redirectPorts = [ 2053 ];
  roles.stream-forwarder = {
    enable = true;
    forwards = [
      {
        listenAddress = "0.0.0.0:8443";
        targetAddress = "${secrets.ip.mokosh.address}:443";
      }
    ];
  };
}
