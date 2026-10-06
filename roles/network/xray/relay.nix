# roles/network/xray/relay.nix
#
# Defines roles.xray.relay: the complete relay mode (Veles-style). Clients
# enter through ingress (VLESS RAW/gRPC/xHTTP on the SNI-routed TCP/443
# backends plus an optional Hysteria2 UDP inbound) and leave through egress:
#   egress.via = "reverse" — the Buyan-initiated reverse links are selected by
#     an observatory-backed leastPing balancer; the only static outbound is
#     the blocked-out blackhole, so new requests fail closed when neither
#     reverse link is healthy.
#   egress.via = "forward" — manual rollback to the classic Veles-initiated
#     forward candidates (primary TCP/443, optional backup port, optional
#     Hysteria2), also falling back to blocked-out.
# The reverse portal clients are advertised whenever egress.reverse.user is
# set, independent of egress.via, so the bridge can connect before cutover.
# When ingress.vless.cdnXhttp is enabled, this role also owns the HTTPS origin
# in the running Nginx (static probe page + /vl-cdn proxy on loopback 9443)
# and the appended SNI-router origin entry; see the cdnXhttp blocks below.
{
  config,
  lib,
  ...
}:

with lib;

let
  cfg = config.roles.xray.relay;
  vless = import ./vless.nix { inherit lib; };
  hysteria = import ./hysteria.nix { inherit lib; };

  ingressCfg = cfg.ingress;
  egressCfg = cfg.egress;
  fwdCfg = egressCfg.forward;

  reverseUser = egressCfg.reverse.user;
  hasReverseUser = reverseUser != null;

  uuidFormat =
    uuid:
    builtins.match "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$" uuid
    != null;

  # The reverse user must appear exactly once in the host-filtered user list
  # and is excluded from every ordinary client list (VLESS and Hysteria2).
  reverseUserMatches = filter (u: u.uuid == reverseUser.uuid) ingressCfg.users;
  normalUsers =
    if hasReverseUser then
      filter (u: u.uuid != reverseUser.uuid) ingressCfg.users
    else
      ingressCfg.users;

  vlessClients = {
    raw = map (u: {
      id = u.uuid;
      flow = "xtls-rprx-vision";
      email = "${u.name}@xray";
    }) normalUsers;
    plain = map (u: {
      id = u.uuid;
      email = "${u.name}@xray";
    }) normalUsers;
  };

  # Optional loopback CDN ingress: XHTTP packet-up behind an HTTPS origin
  # proxy (Nginx), so it carries neither REALITY nor a PROXY-protocol prefix
  # inside Xray. VLESS settings.decryption stays an invalid sentinel in the
  # store template and is injected at runtime from a credential file; a
  # missing credential must fail startup instead of enabling plaintext.
  cdnCfg = ingressCfg.vless.cdnXhttp;
  cdnEnabled = cdnCfg.enable;
  cdnInbound = {
    listen = "127.0.0.1";
    port = 9013;
    tag = "vless-cdn-xhttp-in";
    protocol = "vless";
    settings = {
      clients = vlessClients.plain;
      decryption = "@VLESS_CDN_DECRYPTION@";
    };
    streamSettings = {
      network = "xhttp";
      security = "none";
      xhttpSettings = {
        path = cdnCfg.path;
        mode = "packet-up";
      };
    };
  };

  # Nginx proxy locations for the CDN ingress path: proxyPass carries no URI
  # suffix so Xray sees the complete path, streaming is unbuffered/uncached,
  # and expected Xray 4xx status codes are intercepted as the generic site 404
  # page so a malformed probe cannot fingerprint Xray. One binding is attached
  # to both the exact path and its session subpaths; other prefixes such as
  # /vl-cdn-other must not match.
  cdnProxyLocation = {
    proxyPass = "http://127.0.0.1:${toString cdnInbound.port}";
    extraConfig = ''
      proxy_http_version 1.1;
      proxy_set_header Host $host;
      proxy_set_header Connection "";
      proxy_buffering off;
      proxy_request_buffering off;
      proxy_cache off;
      proxy_read_timeout 3600s;
      proxy_send_timeout 3600s;
      send_timeout 3600s;
      gzip off;
      proxy_intercept_errors on;
      error_page 400 401 403 404 = @probe_404;
      add_header Cache-Control "private, no-store" always;
    '';
  };

  # Reverse-marked portal clients: Xray registers a dynamic outbound under the
  # client's reverse.tag once the bridge connects with this identity.
  reverseClient =
    tag: flow:
    {
      id = reverseUser.uuid;
      email = "${reverseUser.name}@xray";
      reverse.tag = tag;
    }
    // optionalAttrs (flow != null) { inherit flow; };

  ingressTransports = {
    grpc = {
      enable = ingressCfg.vless.grpc.enable;
      sni = ingressCfg.vless.grpc.sni;
      inbound = vless.mkInbound {
        transport = "grpc";
        tag = "vless-grpc-in";
        port = 9011;
        clients = vlessClients.plain;
        sni = ingressCfg.vless.grpc.sni;
        shortIds = ingressCfg.reality.shortIds;
        serviceName = ingressCfg.vless.grpc.serviceName;
      };
    };
    raw = {
      enable = ingressCfg.vless.raw.enable;
      sni = ingressCfg.vless.raw.sni;
      inbound = vless.mkInbound {
        transport = "raw";
        tag = "vless-raw-in";
        port = 9010;
        clients =
          vlessClients.raw
          ++ optionals hasReverseUser [ (reverseClient "reverse-raw-out" "xtls-rprx-vision") ];
        sni = ingressCfg.vless.raw.sni;
        shortIds = ingressCfg.reality.shortIds;
      };
    };
    xhttp = {
      enable = ingressCfg.vless.xhttp.enable;
      sni = ingressCfg.vless.xhttp.sni;
      inbound = vless.mkInbound {
        transport = "xhttp";
        tag = "vless-xhttp-in";
        port = 9012;
        clients =
          vlessClients.plain ++ optionals hasReverseUser [ (reverseClient "reverse-xhttp-out" null) ];
        sni = ingressCfg.vless.xhttp.sni;
        shortIds = ingressCfg.reality.shortIds;
        path = ingressCfg.vless.xhttp.path;
      };
    };
  };
  enabledIngress = filter (t: t.enable) (attrValues ingressTransports);
  hyIngressEnabled = ingressCfg.hysteria2.enable;
  ingressTags =
    (map (t: t.inbound.tag) enabledIngress)
    ++ optional hyIngressEnabled hysteria.relayInboundTag
    ++ optional cdnEnabled cdnInbound.tag;

  reverseMode = egressCfg.via == "reverse";

  # --- Forward egress (manual rollback; inert while egress.via = "reverse") ---
  realityClientSettings = serverName: {
    publicKey = fwdCfg.reality.publicKey;
    shortId = fwdCfg.reality.shortId;
    inherit serverName;
    fingerprint = fwdCfg.reality.fingerprint;
  };

  forwardTransports = {
    grpc = {
      tag = "forward-grpc";
      enable = fwdCfg.vless.grpc.enable;
      sni = fwdCfg.vless.grpc.serverName;
      flow = null;
      streamSettings = {
        network = "grpc";
        security = "reality";
        realitySettings = realityClientSettings fwdCfg.vless.grpc.serverName;
        grpcSettings.serviceName = fwdCfg.vless.grpc.serviceName;
      };
    };
    raw = {
      tag = "forward-raw";
      enable = fwdCfg.vless.raw.enable;
      sni = fwdCfg.vless.raw.serverName;
      flow = "xtls-rprx-vision";
      streamSettings = {
        network = "tcp";
        security = "reality";
        realitySettings = realityClientSettings fwdCfg.vless.raw.serverName;
      };
    };
    xhttp = {
      tag = "forward-xhttp";
      enable = fwdCfg.vless.xhttp.enable;
      sni = fwdCfg.vless.xhttp.serverName;
      flow = null;
      streamSettings = {
        network = "xhttp";
        security = "reality";
        realitySettings = realityClientSettings fwdCfg.vless.xhttp.serverName;
        xhttpSettings.path = fwdCfg.vless.xhttp.path;
      };
    };
  };
  enabledForward = filter (t: t.enable) (attrValues forwardTransports);
  hyForwardEnabled = fwdCfg.hysteria2.enable;
  backupEnabled = fwdCfg.backupPort != null;

  fragmentOutbound =
    outbound:
    if config.roles.xray.fragmentClientHello then
      vless.withClientHelloFragmentation outbound
    else
      outbound;

  forwardOutbounds =
    concatMap (
      t:
      [
        # Primary candidate (TCP/443 on the forward target).
        (fragmentOutbound (
          vless.mkRegularOutbound {
            tag = "${t.tag}-out";
            address = fwdCfg.server;
            port = 443;
            uuid = fwdCfg.user.uuid;
            flow = t.flow;
            streamSettings = t.streamSettings;
          }
        ))
      ]
      ++ optionals backupEnabled [
        # Backup candidate on the configured backup port (e.g. TCP/2053, the
        # REDIRECTed SNI-router port on the target host).
        (fragmentOutbound (
          vless.mkRegularOutbound {
            tag = "${t.tag}-backup-out";
            address = fwdCfg.server;
            port = fwdCfg.backupPort;
            uuid = fwdCfg.user.uuid;
            flow = t.flow;
            streamSettings = t.streamSettings;
          }
        ))
      ]
    ) enabledForward
    ++ optional hyForwardEnabled (
      hysteria.mkRelayOutbound {
        cfg = fwdCfg.hysteria2;
        user = fwdCfg.user;
        serverAddr = fwdCfg.server;
      }
    );

  forwardBalancerTags =
    (map (t: "${t.tag}-out") enabledForward)
    ++ optionals backupEnabled (map (t: "${t.tag}-backup-out") enabledForward)
    ++ optional hyForwardEnabled hysteria.relayOutboundTag;

  relayConfig = {
    log = {
      loglevel = "info";
    };
    inbounds =
      (map (t: t.inbound) enabledIngress)
      ++ optional hyIngressEnabled (
        hysteria.mkRelayInbound {
          cfg = ingressCfg.hysteria2;
          users = normalUsers;
        }
      )
      ++ optional cdnEnabled cdnInbound;
    outbounds = [
      {
        protocol = "blackhole";
        tag = "blocked-out";
      }
    ]
    ++ optionals (!reverseMode) forwardOutbounds;
    routing = {
      rules = [
        {
          type = "field";
          inboundTag = ingressTags;
          balancerTag = if reverseMode then "reverse-balancer" else "forward-balancer";
        }
      ];
      balancers =
        optionals reverseMode [
          {
            tag = "reverse-balancer";
            selector = [
              "reverse-raw-out"
              "reverse-xhttp-out"
            ];
            fallbackTag = "blocked-out";
            strategy.type = "leastPing";
          }
        ]
        ++ optionals (!reverseMode) [
          {
            tag = "forward-balancer";
            selector = forwardBalancerTags;
            fallbackTag = "blocked-out";
            strategy.type = "leastPing";
          }
        ];
    };
    observatory = {
      subjectSelector = [ (if reverseMode then "reverse-" else "forward-") ];
      probeURL = "https://www.google.com/generate_204";
      probeInterval = "60s";
    };
  };
in
{
  options.roles.xray.relay = {
    enable = mkEnableOption "relay clients to another xray host (Veles-style portal)";

    ingress = {
      users = mkOption {
        type = types.listOf types.attrs;
        default = [ ];
        description = "Proxy users allowed on relay inbounds. Each entry must have at least { name, uuid }; the reverse user is excluded from ordinary client lists by the role.";
      };

      reality = {
        privateKeyFile = mkOption {
          type = types.path;
          description = "Path to the REALITY private key file (injected at runtime via LoadCredential, not stored in the template)";
          example = "/etc/nixos/secrets/xray-reality-private-key";
        };
        shortIds = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Authorized REALITY short IDs for relay inbounds";
        };
      };

      vless = {
        raw = {
          enable = mkEnableOption "VLESS RAW (TCP+Vision) relay inbound";
          sni = mkOption {
            type = types.str;
            default = "";
            description = "REALITY SNI of the RAW relay inbound";
          };
        };
        grpc = {
          enable = mkEnableOption "VLESS gRPC relay inbound";
          sni = mkOption {
            type = types.str;
            default = "";
            description = "REALITY SNI of the gRPC relay inbound";
          };
          serviceName = mkOption {
            type = types.str;
            default = "VlGrpc";
            description = "gRPC serviceName of the relay inbound";
          };
        };
        xhttp = {
          enable = mkEnableOption "VLESS xHTTP relay inbound";
          sni = mkOption {
            type = types.str;
            default = "";
            description = "REALITY SNI of the xHTTP relay inbound";
          };
          path = mkOption {
            type = types.str;
            default = "/vl-xhttp";
            description = "xHTTP path of the relay inbound";
          };
        };

        cdnXhttp = {
          enable = mkEnableOption "VLESS-encrypted xHTTP relay inbound on the loopback origin (no REALITY or TLS inside Xray; the Nginx HTTPS origin fronts it and VLESS decryption is injected at runtime)";
          originDomain = mkOption {
            type = types.str;
            default = "";
            description = "Origin domain of the CDN ingress (the HTTPS origin SNI); must differ from every enabled REALITY ingress SNI";
          };
          path = mkOption {
            type = types.str;
            default = "/vl-cdn";
            description = "xHTTP path of the CDN relay inbound";
          };
          decryptionFile = mkOption {
            type = types.path;
            description = "Path to the installed VLESS decryption value file (loaded at runtime via LoadCredential; the store template keeps an invalid sentinel until injection)";
            example = "/etc/nixos/secrets/vlessenc-decryption-key";
          };
        };
      };

      hysteria2 = hysteria.relayInboundOptions.hysteria;
    };

    egress = {
      via = mkOption {
        type = types.enum [
          "forward"
          "reverse"
        ];
        default = "forward";
        description = "Where ordinary ingress traffic leaves: \"reverse\" routes through the Buyan-initiated reverse links behind the reverse-balancer; \"forward\" selects the classic Veles-initiated candidates (manual rollback). Never an automatic fallback.";
      };

      reverse = {
        user = mkOption {
          type = types.nullOr types.attrs;
          default = null;
          description = "Relay-authorized user entry ({ name, uuid, ... }) authenticated as the reverse portal client on the RAW and xHTTP inbounds. Its presence advertises the portal even while egress.via = \"forward\"; reverse mode requires it.";
        };
      };

      forward = {
        user = mkOption {
          type = types.attrs;
          description = "User credentials for authenticating to the forward target server ({ uuid, name, password, ... })";
        };
        server = mkOption {
          type = types.str;
          default = "";
          description = "Forward target server IP or hostname";
        };
        backupPort = mkOption {
          type = types.nullOr types.port;
          default = null;
          description = "Optional backup forward port; when set, every enabled VLESS forward transport gets a second candidate on it";
        };
        reality = {
          publicKey = mkOption {
            type = types.str;
            default = "";
            description = "Forward target's REALITY public key";
          };
          shortId = mkOption {
            type = types.str;
            default = "";
            description = "Authorized shortId on the forward target";
          };
          fingerprint = mkOption {
            type = types.str;
            default = "chrome";
            description = "uTLS fingerprint for forward candidates";
          };
        };
        vless = {
          raw = {
            enable = mkEnableOption "forward candidate VLESS over direct TCP with Vision flow";
            serverName = mkOption {
              type = types.str;
              default = "";
              description = "REALITY SNI of the forward RAW target";
            };
          };
          grpc = {
            enable = mkEnableOption "forward candidate VLESS over gRPC";
            serverName = mkOption {
              type = types.str;
              default = "";
              description = "REALITY SNI of the forward gRPC target";
            };
            serviceName = mkOption {
              type = types.str;
              default = "VlGrpc";
              description = "gRPC serviceName of the forward target";
            };
          };
          xhttp = {
            enable = mkEnableOption "forward candidate VLESS over xHTTP";
            serverName = mkOption {
              type = types.str;
              default = "";
              description = "REALITY SNI of the forward xHTTP target";
            };
            path = mkOption {
              type = types.str;
              default = "/vl-xhttp";
              description = "xHTTP path of the forward target";
            };
          };
        };
        hysteria2 = hysteria.relayTargetOptions.hysteria;
      };
    };

    _configTemplate = mkOption {
      type = types.attrs;
      internal = true;
      default = { };
      description = "The complete relay-mode config template JSON produced by this module";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = enabledIngress != [ ] || hyIngressEnabled;
        message = "roles.xray.relay requires at least one enabled ingress transport (vless raw/grpc/xhttp or hysteria2)";
      }
      {
        assertion = all (t: !t.enable || t.sni != "") (attrValues ingressTransports);
        message = "every enabled roles.xray.relay.ingress.vless.*.sni must be set";
      }
      {
        assertion = !ingressCfg.vless.grpc.enable || !(hasPrefix "/" ingressCfg.vless.grpc.serviceName);
        message = "roles.xray.relay.ingress.vless.grpc.serviceName must not start with '/'";
      }
      {
        assertion = !hasReverseUser || reverseUser ? uuid && reverseUser.uuid != "";
        message = "roles.xray.relay.egress.reverse.user must have a uuid";
      }
      {
        assertion = !cdnEnabled || (cdnCfg.originDomain != "" && cdnCfg.decryptionFile != "");
        message = "roles.xray.relay.ingress.vless.cdnXhttp requires originDomain and decryptionFile when enabled";
      }
      {
        assertion =
          !cdnEnabled || (hasPrefix "/" cdnCfg.path && cdnCfg.path != "/" && !(hasSuffix "/" cdnCfg.path));
        message = "roles.xray.relay.ingress.vless.cdnXhttp.path must start with '/' and must not be or end with '/'";
      }
      {
        assertion =
          !cdnEnabled || all (t: !t.enable || cdnCfg.originDomain != t.sni) (attrValues ingressTransports);
        message = "roles.xray.relay.ingress.vless.cdnXhttp.originDomain must differ from every enabled REALITY ingress SNI";
      }
      {
        assertion = !hasReverseUser || uuidFormat reverseUser.uuid;
        message = "roles.xray.relay.egress.reverse.user must have a valid UUID";
      }
      {
        assertion = !hasReverseUser || reverseUser ? name;
        message = "roles.xray.relay.egress.reverse.user must have a name";
      }
      {
        assertion = !hasReverseUser || length reverseUserMatches == 1;
        message = "roles.xray.relay: the reverse user must appear exactly once in roles.xray.relay.ingress.users";
      }
      {
        assertion = !reverseMode || hasReverseUser;
        message = "roles.xray.relay.egress.via = \"reverse\" requires roles.xray.relay.egress.reverse.user";
      }
      {
        assertion =
          reverseMode
          || (
            fwdCfg.user ? uuid
            && fwdCfg.user.uuid != ""
            && fwdCfg.server != ""
            && (enabledForward != [ ] || hyForwardEnabled)
          );
        message = "roles.xray.relay.egress.via = \"forward\" requires forward.user, forward.server and at least one enabled forward target";
      }
      {
        assertion =
          reverseMode
          || (
            fwdCfg.reality.publicKey != "" && fwdCfg.reality.shortId != "" && fwdCfg.reality.fingerprint != ""
          );
        message = "roles.xray.relay.egress.forward.reality.{publicKey,shortId,fingerprint} must be set in forward mode";
      }
      {
        assertion = reverseMode || all (t: !t.enable || t.sni != "") (attrValues forwardTransports);
        message = "every enabled roles.xray.relay.egress.forward.vless.*.serverName must be set";
      }
      {
        assertion = reverseMode || fwdCfg.backupPort == null || fwdCfg.backupPort != 443;
        message = "roles.xray.relay.egress.forward.backupPort must differ from the primary forward port 443";
      }
      {
        assertion =
          !(hyForwardEnabled && fwdCfg.hysteria2.insecure && fwdCfg.hysteria2.certificateFingerprint != null);
        message = "roles.xray.relay.egress.forward.hysteria2 must not combine insecure = true with certificateFingerprint; set insecure = false or clear the pin (and never enable this target without deployed-binary pin verification)";
      }
      {
        # certFile/keyFile are types.path with no default, so an unset value
        # already fails at module-evaluation time before this assertion runs;
        # the != null check here is a defensive guard, not the primary check.
        assertion =
          !hyIngressEnabled
          || (ingressCfg.hysteria2.certFile != null && ingressCfg.hysteria2.keyFile != null);
        message = "roles.xray.relay.ingress.hysteria2 requires certFile and keyFile";
      }
      {
        assertion = !hyIngressEnabled || any (u: u.password != null && u.password != "") ingressCfg.users;
        message = "roles.xray.relay.ingress.hysteria2 requires at least one user with a non-empty password";
      }
    ];

    networking.firewall.allowedUDPPorts = optional hyIngressEnabled ingressCfg.hysteria2.port;

    # HTTPS origin fronting the CDN ingress, owned by this role in the already
    # running Nginx (enabled by the SNI-router). Explicit listeners keep the
    # public 443 with the stream block and put the origin HTTPS on loopback
    # 9443 consuming the stream router's PROXY protocol; only TCP/80 is added
    # for the HTTP-01 challenge (already firewall-opened by common/server.nix).
    # NixOS's enableACME issues/renews the origin certificate and reloads
    # nginx.service automatically; roles.letsencrypt (Cloudflare DNS-01) is
    # deliberately not used.
    services.nginx = mkIf cdnEnabled {
      virtualHosts.${cdnCfg.originDomain} = {
        enableACME = true;
        listen = [
          {
            addr = "0.0.0.0";
            port = 80;
          }
          {
            addr = "127.0.0.1";
            port = 9443;
            ssl = true;
            proxyProtocol = true;
          }
        ];
        locations = {
          "= /".extraConfig = ''
            default_type text/html;
            add_header Cache-Control "private, no-store" always;
            return 200 '<!doctype html><html lang="en"><meta charset="utf-8"><title>Sunny Bee</title><h1>Sunny Bee</h1></html>';
          '';
          "/".extraConfig = ''
            default_type text/html;
            add_header Cache-Control "private, no-store" always;
            return 404 '<!doctype html><html lang="en"><title>Not Found</title><h1>Not Found</h1></html>';
          '';
          "@probe_404".extraConfig = ''
            default_type text/html;
            add_header Cache-Control "private, no-store" always;
            return 404 '<!doctype html><html lang="en"><title>Not Found</title><h1>Not Found</h1></html>';
          '';
          "= ${cdnCfg.path}" = cdnProxyLocation;
          "^~ ${cdnCfg.path}/" = cdnProxyLocation;
        };
      };
    };

    # Required by the ACME module once the origin certificate exists.
    security.acme = mkIf cdnEnabled {
      acceptTerms = true;
      defaults.email = "stepan@uspenskiy.su";
    };

    roles.xray.relay._configTemplate = relayConfig;
  };
}
