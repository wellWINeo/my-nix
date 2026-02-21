{
  config,
  lib,
  ...
}:
with lib;

let
  cfg = config.roles.stream-forwarder;

  proxyTimeout = "600s";
  proxyConnectTimeout = "5s";

  extractPort = addr: lib.toInt (lib.last (lib.splitString ":" addr));

  mkServerBlock = proto: fwd: ''
    server {
      listen ${fwd.listenAddress}${lib.optionalString (proto == "udp") " udp"};
      proxy_pass ${fwd.targetAddress};
      proxy_timeout ${proxyTimeout};
      proxy_connect_timeout ${proxyConnectTimeout};
    }
  '';
in
{
  options.roles.stream-forwarder = {
    enable = mkEnableOption "nginx stream-based TCP/UDP forwarder";

    forwards = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            listenAddress = mkOption {
              type = types.str;
              example = "0.0.0.0:8388";
              description = "Address:port to listen on";
            };
            targetAddress = mkOption {
              type = types.str;
              example = "10.0.0.1:8388";
              description = "Address:port to forward traffic to";
            };
          };
        }
      );
      default = [ ];
      description = "List of forward configurations";
    };
  };

  config = mkIf cfg.enable {
    services.nginx = {
      enable = true;
      streamConfig = lib.concatMapStrings (
        fwd: mkServerBlock "tcp" fwd + mkServerBlock "udp" fwd
      ) cfg.forwards;
    };

    networking.firewall.allowedTCPPorts = map extractPort (map (f: f.listenAddress) cfg.forwards);
    networking.firewall.allowedUDPPorts = map extractPort (map (f: f.listenAddress) cfg.forwards);
  };
}
