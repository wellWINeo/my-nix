# roles/network/xray/subscriptions.nix
#
# Serves per-user xray subscription files (base64-encoded lists of vless://
# URIs) over HTTPS at /xray-config/<uuid>. Can run co-located with
# roles.xray.server (reusing the 443 stream SNI routing) or on a standalone
# host that only serves subscriptions.
#
# When co-located, roles.xray.subscriptions.upstream.* defaults to the local
# server's values so users typically only set { enable, sni, cert, key }.
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.roles.xray.subscriptions;
  serverCfg = config.roles.xray.server;
  secrets = import ../../../secrets;
  transports = import ./transports { inherit lib; };
  transportList = lib.attrValues transports;

  coLocated = config.roles.xray.enable && serverCfg.enable;

  listenPort = if coLocated then 8444 else 443;
  listenAddr = if coLocated then "127.0.0.1" else "0.0.0.0";
in
{
  options.roles.xray.subscriptions = {
    enable = mkEnableOption "serve per-user xray subscriptions over HTTPS";

    users = mkOption {
      type = types.listOf types.attrs;
      default = [ ];
      description = "Proxy users to generate subscriptions for. Each entry must have at least { name, uuid }.";
    };

    sni = mkOption {
      type = types.str;
      description = "SNI/hostname of the subscription endpoint (e.g. config.example.com)";
    };

    cert = mkOption {
      type = types.path;
      description = "TLS certificate path for the subscription vhost";
    };

    key = mkOption {
      type = types.path;
      description = "TLS private key path for the subscription vhost";
    };

    fingerprint = mkOption {
      type = types.str;
      default = "chrome";
      description = "Default uTLS fingerprint embedded in generated vless URIs";
    };

    upstream = {
      publicAddress = mkOption {
        type = types.str;
        default = "";
        description = "Public hostname of the xray server to advertise in generated URIs. Defaults to roles.xray.server.publicAddress when co-located.";
      };

      realityPublicKey = mkOption {
        type = types.str;
        default = "";
        description = "Reality public key of the upstream xray server. Defaults to roles.xray.server.reality.publicKey when co-located.";
      };
    }
    // lib.mapAttrs (_: t: t.subscriptionUpstreamOptions) transports;
  };

  config = mkIf (config.roles.xray.enable && cfg.enable) (
    let
      enabledUpstreamTransports = lib.filter (t: cfg.upstream.${t.name}.enable) transportList;

      shortIdHead =
        if (secrets.xray.reality.shortIds or [ ]) != [ ] then
          builtins.head secrets.xray.reality.shortIds
        else
          "";

      # Build one user's newline-joined list of vless:// URIs.
      userUrisText =
        user:
        let
          uris = map (
            t:
            t.mkSubscriptionEntry {
              serverAddr = cfg.upstream.publicAddress;
              uuid = user.uuid;
              fingerprint = cfg.fingerprint;
              realityPublicKey = cfg.upstream.realityPublicKey;
              shortId = shortIdHead;
              cfg = cfg.upstream.${t.name};
            }
          ) enabledUpstreamTransports;
        in
        lib.concatStringsSep "\n" uris;

      subscriptionsDir = pkgs.runCommand "xray-subscriptions" { } (
        ''
          mkdir -p $out
        ''
        + lib.concatMapStrings (u: ''
          printf '%s' ${lib.escapeShellArg (userUrisText u)} | base64 -w0 > $out/${u.uuid}
        '') cfg.users
      );
    in
    {
      assertions = [
        {
          assertion = cfg.upstream.publicAddress != "";
          message = "roles.xray.subscriptions.upstream.publicAddress must be set (explicitly or via roles.xray.server.publicAddress when co-located)";
        }
        {
          assertion = cfg.upstream.realityPublicKey != "";
          message = "roles.xray.subscriptions.upstream.realityPublicKey must be set";
        }
        {
          assertion = shortIdHead != "";
          message = "secrets.xray.reality.shortIds must be non-empty for subscription generation";
        }
        {
          assertion = lib.any (t: cfg.upstream.${t.name}.enable) transportList;
          message = "At least one roles.xray.subscriptions.upstream.<transport>.enable must be true";
        }
      ];

      # Co-located default: mirror local server values unless overridden.
      roles.xray.subscriptions.upstream = mkIf coLocated (
        {
          publicAddress = mkDefault serverCfg.publicAddress;
          realityPublicKey = mkDefault serverCfg.reality.publicKey;
        }
        // lib.mapAttrs (
          name: t:
          let
            sCfg = serverCfg.${name};
          in
          {
            enable = mkDefault sCfg.enable;
            sni = mkDefault sCfg.sni;
          }
          // lib.optionalAttrs (name == "vlessGrpc") { serviceName = mkDefault sCfg.serviceName; }
          // lib.optionalAttrs (name == "vlessXhttp") { path = mkDefault sCfg.path; }
        ) transports
      );

      services.nginx = {
        enable = true;

        commonHttpConfig = ''
          limit_req_zone $binary_remote_addr zone=xray_config:10m rate=10r/m;
        '';

        virtualHosts."${cfg.sni}" = {
          listen = [
            {
              addr = listenAddr;
              port = listenPort;
              ssl = true;
            }
          ];
          sslCertificate = cfg.cert;
          sslCertificateKey = cfg.key;

          locations."~ ^/xray-config/(?<sub_uuid>[A-Za-z0-9-]+)$" = {
            extraConfig = ''
              alias ${subscriptionsDir}/$sub_uuid;
              default_type text/plain;
              autoindex off;
              limit_req zone=xray_config burst=5 nodelay;
              add_header Cache-Control "no-store";
            '';
          };
        };
      };

      # When standalone, open 443 directly. When co-located, 443 is already
      # open and stream-mapped by default.nix.
      networking.firewall.allowedTCPPorts = mkIf (!coLocated) [ 443 ];
    }
  );
}
