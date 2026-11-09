{
  ifname,
  ip,
  gatewayIP,
}:

{ config, ... }:

let
  hostname = config.networking.hostName;
  secrets = import ../../secrets;
  mokoshIp = secrets.ip.mokosh.address;
  selectProxyUser = import ../../common/select-proxy-user.nix;
  nixpiXrayUser = selectProxyUser hostname secrets.singBoxUsers;
in
{
  imports = [ ../../roles ];

  roles.share = {
    hostname = hostname;
    enable = true;
    enableTimeMachine = true;
  };

  roles.media.enable = true;
  roles.torrent.enable = true;
  roles.dns = {
    enable = true;
    openFirewall = true;
    useLocalDNS = true;
    ipAddress = ip;
    metrics.enable = true;
  };

  roles.observability.agent.enable = true;

  roles.dhcp = {
    enable = true;
    openFirewall = true;
    hostMAC = "DC:A6:32:07:25:C1";
    hostIP = ip;
    gatewayIP = gatewayIP;
  };

  roles.shadowsocks-client = {
    enable = true;
    host = "gw.uspenskiy.su";
    openFirewall = true;
  };

  roles.wireguard-client = {
    enable = true;
    ip = "10.20.0.25";
    endpoint = "${mokoshIp}:51820";
    serverPubKey = secrets.wireguard.mokosh-pubkey;
  };

  services.tailscale = {
    enable = true;
    openFirewall = true;
    disableUpstreamLogging = true;
    extraSetFlags = [ "--accept-dns=false" ];
  };

  roles.xray = {
    client = {
      enable = true;
      ingress = {
        socks.port = 1081;
        http.enable = true;
        openFirewall = true;
        tunnels = [
          {
            listen = "127.0.0.1:5053";
            target = "1.1.1.1:853";
          }
        ];
      };

      egress = {
        server = secrets.ip.veles.address;
        user = nixpiXrayUser;
        backupPort = 2053;
        reality = {
          publicKey = secrets.xray.reality.publicKey;
          shortId = builtins.head secrets.xray.reality.shortIds;
          fingerprint = "randomized";
        };
        vless = {
          raw = {
            enable = true;
            serverName = "api.oneme.ru";
          };
          grpc = {
            enable = true;
            serverName = "avatars.mds.yandex.net";
          };
          xhttp = {
            enable = true;
            serverName = "onlymir.ru";
          };
        };
      };
    };
  };

  roles.home-nginx = {
    enable = true;
    ip = ip;
  };

  roles.photos = {
    enable = true;
    storagePath = "/mnt/storage/Photos";
  };

  roles.zeroconf.enable = true;

}
