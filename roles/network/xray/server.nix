# roles/network/xray/server.nix
#
# Defines roles.xray.server options and exports _serverConfig fragment by
# folding over the transport registry. The coordinator (default.nix) still
# owns systemd, nginx, and firewall.
{
  config,
  lib,
  ...
}:

with lib;

let
  cfg = config.roles.xray.server;
  secrets = import ../../../secrets;
  filterProxyUsersForHost = import ../../../common/filter-proxy-users.nix { inherit lib; };
  transports = import ./transports { inherit lib; };
  transportList = lib.attrValues transports;

  shortIds = secrets.xray.reality.shortIds or [ ];
  users = filterProxyUsersForHost config.networking.hostName secrets.singBoxUsers;

  clients = {
    withFlow = map (u: {
      id = u.uuid;
      flow = "xtls-rprx-vision";
      email = "${u.name}@xray";
    }) users;

    noFlow = map (u: {
      id = u.uuid;
      email = "${u.name}@xray";
    }) users;
  };

  enabledTransports = lib.filter (t: cfg.${t.name}.enable) transportList;

  serverConfig = {
    inbounds = map (
      t:
      t.mkServerInbound {
        cfg = cfg.${t.name};
        inherit clients shortIds;
      }
    ) enabledTransports;

    outbounds = [
      {
        protocol = "freedom";
        tag = "direct-out";
      }
    ];

    routing = {
      rules = [
        {
          type = "field";
          inboundTag = map (t: "${t.tagPrefix}-in") enabledTransports;
          outboundTag = "direct-out";
        }
      ];
      balancers = [ ];
    };

    nginxSniEntries = map (t: {
      sni = cfg.${t.name}.sni;
      port = t.serverPort;
    }) enabledTransports;
  };
in
{
  options.roles.xray.server = {
    enable = mkEnableOption "xray anti-censorship proxy server with Reality";

    reality = {
      privateKeyFile = mkOption {
        type = types.path;
        description = "Path to the Reality private key file on disk (not stored in Nix store)";
        example = "/etc/nixos/secrets/xray-reality-private-key";
      };

      publicKey = mkOption {
        type = types.str;
        default = "";
        description = "Reality public key (public, not secret). Required when subscriptions are enabled.";
      };
    };

    publicAddress = mkOption {
      type = types.str;
      default = "";
      description = "Public hostname clients use to reach this xray server. Required when subscriptions are enabled.";
    };
  }
  // lib.mapAttrs (_: t: t.serverOptions) transports;

  config = mkIf (config.roles.xray.enable && cfg.enable) {
    assertions = [
      {
        assertion = (secrets.xray.reality.shortIds or [ ]) != [ ];
        message = "secrets.xray.reality.shortIds must be set before deploying xray server";
      }
      {
        assertion = lib.any (t: cfg.${t.name}.enable) transportList;
        message = "At least one xray server transport must be enabled";
      }
      {
        assertion = !cfg.vlessGrpc.enable || !(lib.hasPrefix "/" cfg.vlessGrpc.serviceName);
        message = "roles.xray.server.vlessGrpc.serviceName must not start with '/'";
      }
    ];

    roles.xray._serverConfig = serverConfig;
  };
}
