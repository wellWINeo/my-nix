{
  config,
  pkgs,
  lib,
  ...
}:
with lib;

let
  cfg = config.roles.shadowsocks-server;
  port = 8388;
in
{
  disabledModules = [ "services/networking/shadowsocks.nix" ];

  imports = [ ../../common/shadowsocks.nix ];

  options.roles.shadowsocks-server = {
    enable = mkEnableOption "Enable ShadowSocks Server";
    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open firewall";
    };

    baseDomain = mkOption {
      type = types.str;
      description = "Domain";
    };

    enableWeb = mkEnableOption "Enable web";
  };

  config = mkIf cfg.enable {
    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = optionals [ port ];
      allowedUDPPorts = optionals [ port ];
    };

    services.shadowsocks = {
      enable = true;
      isServer = true;
      package = pkgs.shadowsocks-rust;
      port = port;
      plugin = "${pkgs.shadowsocks-v2ray-plugin}/bin/v2ray-plugin";
      mode = "tcp_and_udp";
      localAddress = "0.0.0.0";
      fastOpen = true;
      passwordFile = "/etc/nixos/secrets/shadowsocksPassword";
      encryptionMethod = "aes-256-gcm";
      pluginOpts = "server";
      extraConfig = {
        nameserver = "1.1.1.1";
      };
    };

    services.nginx = {
      enable = true;

      virtualHosts."gw.${cfg.baseDomain}" = {
        forceSSL = true;
        enableACME = false;

        sslCertificate = "/var/lib/acme/${cfg.baseDomain}/fullchain.pem";
        sslCertificateKey = "/var/lib/acme/${cfg.baseDomain}/key.pem";

        locations."/".return = "301 https://google.com/search?q=$request_uri";

        locations."/fckrkn" = {
          proxyPass = "http://127.0.0.1:8388/";
          extraConfig = ''
            proxy_redirect off;
            proxy_buffering off;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";          
          '';
        };
      };
    };
  };
}
