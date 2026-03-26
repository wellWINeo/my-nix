# Xray Unified Module with Relay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Unify xray server/client/relay under `roles.xray` with a new relay capability that forwards traffic to another xray server using leastPing balancing.

**Architecture:** A coordinator `default.nix` imports three sub-modules (server, client, relay) and merges their config fragments into a single xray process. Shared transport option helpers in `options.nix` eliminate duplication between client and relay. The relay adds `-fwd` inbounds on separate ports with distinct SNIs, and outbounds to the target server via a leastPing balancer.

**Tech Stack:** NixOS modules, xray-core, nginx stream (L4 SNI routing)

**Spec:** `docs/superpowers/specs/2026-03-26-xray-relay-design.md`

---

### Task 1: Create `options.nix` — shared transport option helpers

**Files:**
- Create: `roles/network/xray/options.nix`

This file exports functions that generate NixOS option attribute sets, used by both `client.nix` and `relay.nix`.

- [ ] **Step 1: Create `options.nix` with all helper functions**

```nix
# roles/network/xray/options.nix
#
# Shared option builders for xray transport configuration.
# Used by client.nix (full options) and relay.nix (target options, no server/port/auth).
{ lib }:

with lib;

{
  # Reality TLS client options (for connecting TO an xray server).
  mkRealityClientOptions =
    {
      defaults ? { },
    }:
    {
      enable = mkEnableOption "Reality TLS";

      publicKey = mkOption {
        type = types.str;
        default = defaults.publicKey or "";
        description = "Server's Reality public key";
      };

      shortId = mkOption {
        type = types.str;
        default = defaults.shortId or "";
        description = "Authorized shortId for authentication";
      };

      serverName = mkOption {
        type = types.str;
        default = defaults.serverName or "";
        description = "SNI to present during TLS handshake (fallback when transport doesn't override)";
      };

      fingerprint = mkOption {
        type = types.str;
        default = defaults.fingerprint or "chrome";
        description = "uTLS fingerprint (chrome, firefox, safari, etc.)";
      };
    };

  # VLESS TCP transport options.
  # When includeConnection = true, includes server/port/auth (for client).
  # When false, only includes serverName (for relay target).
  mkVlessTcpOptions =
    {
      includeConnection ? true,
      defaults ? { },
    }:
    {
      enable = mkEnableOption "VLESS over direct TCP with Vision flow";

      serverName = mkOption {
        type = types.str;
        default = defaults.serverName or "";
        description = "Reality SNI for this transport (overrides shared reality.serverName)";
      };
    }
    // optionalAttrs includeConnection {
      server = mkOption {
        type = types.str;
        description = "Server domain or IP";
      };

      port = mkOption {
        type = types.port;
        default = defaults.port or 443;
        description = "Server port";
      };

      auth = {
        name = mkOption {
          type = types.str;
          default = "";
          description = "Username (informational only; xray VLESS uses UUID)";
        };
        uuid = mkOption {
          type = types.str;
          description = "UUID for authentication";
        };
      };
    };

  # VLESS gRPC transport options.
  mkVlessGrpcOptions =
    {
      includeConnection ? true,
      defaults ? { },
    }:
    {
      enable = mkEnableOption "VLESS over gRPC";

      serviceName = mkOption {
        type = types.str;
        default = defaults.serviceName or "VlGrpc";
        description = "gRPC service name (must match server)";
      };

      serverName = mkOption {
        type = types.str;
        default = defaults.serverName or "";
        description = "Reality SNI for this transport (overrides shared reality.serverName)";
      };
    }
    // optionalAttrs includeConnection {
      server = mkOption {
        type = types.str;
        description = "Server domain or IP";
      };

      port = mkOption {
        type = types.port;
        default = defaults.port or 443;
        description = "Server port";
      };

      auth = {
        name = mkOption {
          type = types.str;
          default = "";
          description = "Username (informational only)";
        };
        uuid = mkOption {
          type = types.str;
          description = "UUID for authentication";
        };
      };
    };

  # VLESS xHTTP transport options.
  mkVlessXhttpOptions =
    {
      includeConnection ? true,
      defaults ? { },
    }:
    {
      enable = mkEnableOption "VLESS over xHTTP";

      path = mkOption {
        type = types.str;
        default = defaults.path or "/vl-xhttp";
        description = "xHTTP path";
      };

      serverName = mkOption {
        type = types.str;
        default = defaults.serverName or "";
        description = "Reality SNI for this transport (overrides shared reality.serverName)";
      };
    }
    // optionalAttrs includeConnection {
      server = mkOption {
        type = types.str;
        description = "Server domain or IP";
      };

      port = mkOption {
        type = types.port;
        default = defaults.port or 443;
        description = "Server port";
      };

      auth = {
        name = mkOption {
          type = types.str;
          default = "";
          description = "Username (informational only)";
        };
        uuid = mkOption {
          type = types.str;
          description = "UUID for authentication";
        };
      };
    };
}
```

- [ ] **Step 2: Commit**

```bash
git add roles/network/xray/options.nix
git commit -m "feat(xray): add shared transport option helpers"
```

---

### Task 2: Refactor `server.nix` — export config fragment, re-root options

**Files:**
- Modify: `roles/network/xray/server.nix` (full rewrite)

Strip out systemd, nginx, and firewall config. Re-root options from `roles.xray-server` to `roles.xray.server`. Export config fragment via `roles.xray._serverConfig`.

- [ ] **Step 1: Rewrite `server.nix`**

```nix
# roles/network/xray/server.nix
#
# Defines roles.xray.server options and exports _serverConfig fragment.
# The coordinator (default.nix) owns systemd, nginx, and firewall.
{
  config,
  lib,
  ...
}:

with lib;

let
  cfg = config.roles.xray.server;
  secrets = import ../../../secrets;

  vlessTcpPort = 9000;
  vlessGrpcPort = 9001;
  vlessXhttpPort = 9002;

  # Clients with Vision flow (TCP only)
  vlessTcpClients = map (u: {
    id = u.uuid;
    flow = "xtls-rprx-vision";
    email = "${u.name}@xray";
  }) secrets.singBoxUsers;

  # Clients without flow (gRPC, xHTTP)
  vlessClients = map (u: {
    id = u.uuid;
    email = "${u.name}@xray";
  }) secrets.singBoxUsers;

  # Shared Reality settings (privateKey injected at runtime by coordinator)
  mkRealitySettings = sni: {
    target = "${sni}:443";
    serverNames = [ sni ];
    shortIds = secrets.xray.reality.shortIds or [ ];
  };

  serverConfig = {
    inbounds =
      lib.optionals cfg.vlessTcp.enable [
        {
          listen = "127.0.0.1";
          port = vlessTcpPort;
          protocol = "vless";
          tag = "vless-tcp-in";
          settings = {
            clients = vlessTcpClients;
            decryption = "none";
          };
          streamSettings = {
            network = "tcp";
            security = "reality";
            realitySettings = mkRealitySettings cfg.vlessTcp.sni;
            sockopt.acceptProxyProtocol = true;
          };
        }
      ]
      ++ lib.optionals cfg.vlessGrpc.enable [
        {
          listen = "127.0.0.1";
          port = vlessGrpcPort;
          protocol = "vless";
          tag = "vless-grpc-in";
          settings = {
            clients = vlessClients;
            decryption = "none";
          };
          streamSettings = {
            network = "grpc";
            security = "reality";
            realitySettings = (mkRealitySettings cfg.vlessGrpc.sni) // {
              alpn = [ "h2" ];
            };
            grpcSettings = {
              serviceName = cfg.vlessGrpc.serviceName;
            };
            sockopt.acceptProxyProtocol = true;
          };
        }
      ]
      ++ lib.optionals cfg.vlessXhttp.enable [
        {
          listen = "127.0.0.1";
          port = vlessXhttpPort;
          protocol = "vless";
          tag = "vless-xhttp-in";
          settings = {
            clients = vlessClients;
            decryption = "none";
          };
          streamSettings = {
            network = "xhttp";
            security = "reality";
            realitySettings = mkRealitySettings cfg.vlessXhttp.sni;
            xhttpSettings = {
              path = cfg.vlessXhttp.path;
            };
            sockopt.acceptProxyProtocol = true;
          };
        }
      ];

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
          inboundTag =
            lib.optionals cfg.vlessTcp.enable [ "vless-tcp-in" ]
            ++ lib.optionals cfg.vlessGrpc.enable [ "vless-grpc-in" ]
            ++ lib.optionals cfg.vlessXhttp.enable [ "vless-xhttp-in" ];
          outboundTag = "direct-out";
        }
      ];
      balancers = [ ];
    };

    nginxSniEntries =
      lib.optionals cfg.vlessTcp.enable [
        {
          sni = cfg.vlessTcp.sni;
          port = vlessTcpPort;
        }
      ]
      ++ lib.optionals cfg.vlessGrpc.enable [
        {
          sni = cfg.vlessGrpc.sni;
          port = vlessGrpcPort;
        }
      ]
      ++ lib.optionals cfg.vlessXhttp.enable [
        {
          sni = cfg.vlessXhttp.sni;
          port = vlessXhttpPort;
        }
      ];
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
    };

    vlessTcp = {
      enable = mkEnableOption "VLESS over direct TCP with Vision flow";
      sni = mkOption {
        type = types.str;
        default = "api.oneme.ru";
        description = "Reality SNI and camouflage target for TCP+Vision transport";
      };
    };

    vlessGrpc = {
      enable = mkEnableOption "VLESS over gRPC";
      sni = mkOption {
        type = types.str;
        default = "avatars.mds.yandex.net";
        description = "Reality SNI and camouflage target for gRPC transport";
      };
      serviceName = mkOption {
        type = types.str;
        default = "VlGrpc";
        description = "gRPC service name (no leading slash)";
      };
    };

    vlessXhttp = {
      enable = mkEnableOption "VLESS over xHTTP";
      sni = mkOption {
        type = types.str;
        default = "onlymir.ru";
        description = "Reality SNI and camouflage target for xHTTP transport";
      };
      path = mkOption {
        type = types.str;
        default = "/vl-xhttp";
        description = "xHTTP path";
      };
    };
  };

  config = mkIf (config.roles.xray.enable && cfg.enable) {
    assertions = [
      {
        assertion = !(lib.hasPrefix "/" cfg.vlessGrpc.serviceName);
        message = "roles.xray.server.vlessGrpc.serviceName must not start with '/'";
      }
      {
        assertion = (secrets.xray.reality.shortIds or [ ]) != [ ];
        message = "secrets.xray.reality.shortIds must be set before deploying xray server";
      }
      {
        assertion = cfg.vlessTcp.enable || cfg.vlessGrpc.enable || cfg.vlessXhttp.enable;
        message = "At least one xray server transport must be enabled";
      }
    ];

    roles.xray._serverConfig = serverConfig;
  };
}
```

- [ ] **Step 2: Commit**

```bash
git add roles/network/xray/server.nix
git commit -m "refactor(xray): re-root server options under roles.xray.server, export config fragment"
```

---

### Task 3: Refactor `client.nix` — use shared options, re-root under `roles.xray.client`

**Files:**
- Modify: `roles/network/xray/client.nix` (full rewrite)

Replace inline option definitions with calls to `options.nix` helpers. Re-root from `roles.xray-client` to `roles.xray.client`. Client still runs its own independent xray process via `services.xray`.

- [ ] **Step 1: Rewrite `client.nix`**

```nix
# roles/network/xray/client.nix
#
# Defines roles.xray.client options. Runs its own xray process (independent
# from server/relay). Uses shared option helpers from options.nix.
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.roles.xray.client;
  opts = import ./options.nix { inherit lib; };

  # Build streamSettings for a given transport.
  mkStreamSettings =
    transport:
    let
      sni =
        if (transport.serverName or "") != "" then transport.serverName else cfg.reality.serverName;
      securitySettings =
        if cfg.reality.enable then
          {
            security = "reality";
            realitySettings = {
              publicKey = cfg.reality.publicKey;
              shortId = cfg.reality.shortId;
              serverName = sni;
              fingerprint = cfg.reality.fingerprint;
            };
          }
        else
          {
            security = "tls";
            tlsSettings = {
              serverName = transport.server;
            };
          };
    in
    securitySettings // transport.extra;

  xrayConfig = {
    log = {
      loglevel = "info";
    };

    inbounds = [
      {
        listen = "0.0.0.0";
        port = cfg.port;
        protocol = "socks";
        tag = "socks-in";
        settings = {
          auth = "noauth";
          udp = true;
        };
      }
    ];

    outbounds =
      lib.optionals cfg.vlessTcp.enable [
        {
          protocol = "vless";
          tag = "vless-tcp-out";
          settings = {
            vnext = [
              {
                address = cfg.vlessTcp.server;
                port = cfg.vlessTcp.port;
                users = [
                  {
                    id = cfg.vlessTcp.auth.uuid;
                    flow = "xtls-rprx-vision";
                    encryption = "none";
                  }
                ];
              }
            ];
          };
          streamSettings = mkStreamSettings {
            server = cfg.vlessTcp.server;
            serverName = cfg.vlessTcp.serverName;
            extra = {
              network = "tcp";
            };
          };
        }
      ]
      ++ lib.optionals cfg.vlessGrpc.enable [
        {
          protocol = "vless";
          tag = "vless-grpc-out";
          settings = {
            vnext = [
              {
                address = cfg.vlessGrpc.server;
                port = cfg.vlessGrpc.port;
                users = [
                  {
                    id = cfg.vlessGrpc.auth.uuid;
                    encryption = "none";
                  }
                ];
              }
            ];
          };
          streamSettings = mkStreamSettings {
            server = cfg.vlessGrpc.server;
            serverName = cfg.vlessGrpc.serverName;
            extra = {
              network = "grpc";
              grpcSettings = {
                serviceName = cfg.vlessGrpc.serviceName;
              };
            };
          };
        }
      ]
      ++ lib.optionals cfg.vlessXhttp.enable [
        {
          protocol = "vless";
          tag = "vless-xhttp-out";
          settings = {
            vnext = [
              {
                address = cfg.vlessXhttp.server;
                port = cfg.vlessXhttp.port;
                users = [
                  {
                    id = cfg.vlessXhttp.auth.uuid;
                    encryption = "none";
                  }
                ];
              }
            ];
          };
          streamSettings = mkStreamSettings {
            server = cfg.vlessXhttp.server;
            serverName = cfg.vlessXhttp.serverName;
            extra = {
              network = "xhttp";
              xhttpSettings = {
                path = cfg.vlessXhttp.path;
              };
            };
          };
        }
      ]
      ++ [
        {
          protocol = "freedom";
          tag = "direct-out";
        }
      ];

    routing = {
      rules = [
        {
          type = "field";
          inboundTag = [ "socks-in" ];
          balancerTag = "proxy-balancer";
        }
      ];
      balancers = [
        {
          tag = "proxy-balancer";
          selector =
            lib.optionals cfg.vlessTcp.enable [ "vless-tcp-out" ]
            ++ lib.optionals cfg.vlessGrpc.enable [ "vless-grpc-out" ]
            ++ lib.optionals cfg.vlessXhttp.enable [ "vless-xhttp-out" ];
          strategy = {
            type = "random";
          };
        }
      ];
    };
  };
in
{
  options.roles.xray.client = {
    enable = mkEnableOption "xray proxy client";

    port = mkOption {
      type = types.port;
      default = 1081;
      description = "SOCKS5 listen port";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open firewall for SOCKS port";
    };

    reality = opts.mkRealityClientOptions { };

    vlessTcp = opts.mkVlessTcpOptions { includeConnection = true; };
    vlessGrpc = opts.mkVlessGrpcOptions { includeConnection = true; };
    vlessXhttp = opts.mkVlessXhttpOptions { includeConnection = true; };
  };

  config = mkIf (config.roles.xray.enable && cfg.enable) {
    assertions = [
      {
        assertion = cfg.vlessTcp.enable || cfg.vlessGrpc.enable || cfg.vlessXhttp.enable;
        message = "At least one xray client outbound must be enabled";
      }
      {
        assertion =
          !cfg.reality.enable
          || (
            cfg.reality.publicKey != ""
            && cfg.reality.shortId != ""
            && cfg.reality.serverName != ""
            && cfg.reality.fingerprint != ""
          );
        message = "roles.xray.client.reality.publicKey, shortId, serverName, and fingerprint must be set when reality.enable = true";
      }
    ];

    services.xray = {
      enable = true;
      settings = xrayConfig;
    };

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ];
    networking.firewall.allowedUDPPorts = mkIf cfg.openFirewall [ cfg.port ];
  };
}
```

- [ ] **Step 2: Commit**

```bash
git add roles/network/xray/client.nix
git commit -m "refactor(xray): re-root client options under roles.xray.client, use shared helpers"
```

---

### Task 4: Create `relay.nix` — relay inbounds, outbounds, and balancer

**Files:**
- Create: `roles/network/xray/relay.nix`

Defines `roles.xray.relay` options and exports `_relayConfig` fragment with `-fwd` inbounds, relay outbounds, and leastPing balancer.

- [ ] **Step 1: Create `relay.nix`**

```nix
# roles/network/xray/relay.nix
#
# Defines roles.xray.relay options and exports _relayConfig fragment.
# Relay adds forwarding inbounds (suffixed -fwd/Fwd) that route traffic
# to another xray server via a leastPing balancer.
{
  config,
  lib,
  ...
}:

with lib;

let
  cfg = config.roles.xray.relay;
  serverCfg = config.roles.xray.server;
  secrets = import ../../../secrets;
  opts = import ./options.nix { inherit lib; };

  relayTcpPort = 9010;
  relayGrpcPort = 9011;
  relayXhttpPort = 9012;

  # Relay inbounds reuse the same client lists and Reality settings as
  # the server, but with relay-specific SNIs and ports.

  # Clients with Vision flow (TCP only)
  vlessTcpClients = map (u: {
    id = u.uuid;
    flow = "xtls-rprx-vision";
    email = "${u.name}@xray";
  }) secrets.singBoxUsers;

  # Clients without flow (gRPC, xHTTP)
  vlessClients = map (u: {
    id = u.uuid;
    email = "${u.name}@xray";
  }) secrets.singBoxUsers;

  mkRealitySettings = sni: {
    target = "${sni}:443";
    serverNames = [ sni ];
    shortIds = secrets.xray.reality.shortIds or [ ];
  };

  # Build outbound streamSettings for connecting to the target server.
  mkTargetStreamSettings =
    {
      network,
      serverName,
      extra ? { },
    }:
    let
      sni =
        if serverName != "" then serverName else cfg.target.reality.serverName;
    in
    {
      network = network;
      security = "reality";
      realitySettings = {
        publicKey = cfg.target.reality.publicKey;
        shortId = cfg.target.reality.shortId;
        serverName = sni;
        fingerprint = cfg.target.reality.fingerprint;
      };
    }
    // extra;

  tcpEnabled = cfg.vlessTcp.enable && serverCfg.vlessTcp.enable;
  grpcEnabled = cfg.vlessGrpc.enable && serverCfg.vlessGrpc.enable;
  xhttpEnabled = cfg.vlessXhttp.enable && serverCfg.vlessXhttp.enable;

  relayConfig = {
    inbounds =
      lib.optionals tcpEnabled [
        {
          listen = "127.0.0.1";
          port = relayTcpPort;
          protocol = "vless";
          tag = "vless-tcp-fwd-in";
          settings = {
            clients = vlessTcpClients;
            decryption = "none";
          };
          streamSettings = {
            network = "tcp";
            security = "reality";
            realitySettings = mkRealitySettings cfg.vlessTcp.sni;
            sockopt.acceptProxyProtocol = true;
          };
        }
      ]
      ++ lib.optionals grpcEnabled [
        {
          listen = "127.0.0.1";
          port = relayGrpcPort;
          protocol = "vless";
          tag = "vless-grpcFwd-in";
          settings = {
            clients = vlessClients;
            decryption = "none";
          };
          streamSettings = {
            network = "grpc";
            security = "reality";
            realitySettings = (mkRealitySettings cfg.vlessGrpc.sni) // {
              alpn = [ "h2" ];
            };
            grpcSettings = {
              serviceName = serverCfg.vlessGrpc.serviceName;
            };
            sockopt.acceptProxyProtocol = true;
          };
        }
      ]
      ++ lib.optionals xhttpEnabled [
        {
          listen = "127.0.0.1";
          port = relayXhttpPort;
          protocol = "vless";
          tag = "vless-xhttp-fwd-in";
          settings = {
            clients = vlessClients;
            decryption = "none";
          };
          streamSettings = {
            network = "xhttp";
            security = "reality";
            realitySettings = mkRealitySettings cfg.vlessXhttp.sni;
            xhttpSettings = {
              path = serverCfg.vlessXhttp.path;
            };
            sockopt.acceptProxyProtocol = true;
          };
        }
      ];

    outbounds =
      lib.optionals tcpEnabled [
        {
          protocol = "vless";
          tag = "relay-tcp-out";
          settings = {
            vnext = [
              {
                address = cfg.target.server;
                port = 443;
                users = [
                  {
                    id = cfg.user.uuid;
                    flow = "xtls-rprx-vision";
                    encryption = "none";
                  }
                ];
              }
            ];
          };
          streamSettings = mkTargetStreamSettings {
            network = "tcp";
            serverName = cfg.target.vlessTcp.serverName;
          };
        }
      ]
      ++ lib.optionals grpcEnabled [
        {
          protocol = "vless";
          tag = "relay-grpc-out";
          settings = {
            vnext = [
              {
                address = cfg.target.server;
                port = 443;
                users = [
                  {
                    id = cfg.user.uuid;
                    encryption = "none";
                  }
                ];
              }
            ];
          };
          streamSettings = mkTargetStreamSettings {
            network = "grpc";
            serverName = cfg.target.vlessGrpc.serverName;
            extra = {
              grpcSettings = {
                serviceName = cfg.target.vlessGrpc.serviceName;
              };
            };
          };
        }
      ]
      ++ lib.optionals xhttpEnabled [
        {
          protocol = "vless";
          tag = "relay-xhttp-out";
          settings = {
            vnext = [
              {
                address = cfg.target.server;
                port = 443;
                users = [
                  {
                    id = cfg.user.uuid;
                    encryption = "none";
                  }
                ];
              }
            ];
          };
          streamSettings = mkTargetStreamSettings {
            network = "xhttp";
            serverName = cfg.target.vlessXhttp.serverName;
            extra = {
              xhttpSettings = {
                path = cfg.target.vlessXhttp.path;
              };
            };
          };
        }
      ];

    routing = {
      rules = [
        {
          type = "field";
          inboundTag =
            lib.optionals tcpEnabled [ "vless-tcp-fwd-in" ]
            ++ lib.optionals grpcEnabled [ "vless-grpcFwd-in" ]
            ++ lib.optionals xhttpEnabled [ "vless-xhttp-fwd-in" ];
          balancerTag = "relay-balancer";
        }
      ];
      balancers = [
        {
          tag = "relay-balancer";
          selector =
            lib.optionals tcpEnabled [ "relay-tcp-out" ]
            ++ lib.optionals grpcEnabled [ "relay-grpc-out" ]
            ++ lib.optionals xhttpEnabled [ "relay-xhttp-out" ];
          strategy = {
            type = "leastPing";
          };
        }
      ];
    };

    nginxSniEntries =
      lib.optionals tcpEnabled [
        {
          sni = cfg.vlessTcp.sni;
          port = relayTcpPort;
        }
      ]
      ++ lib.optionals grpcEnabled [
        {
          sni = cfg.vlessGrpc.sni;
          port = relayGrpcPort;
        }
      ]
      ++ lib.optionals xhttpEnabled [
        {
          sni = cfg.vlessXhttp.sni;
          port = relayXhttpPort;
        }
      ];
  };
in
{
  options.roles.xray.relay = {
    enable = mkEnableOption "relay traffic to another xray server";

    user = mkOption {
      type = types.attrs;
      description = "User credentials for authenticating to the target server ({ uuid, name, ... } from secrets.singBoxUsers)";
    };

    target = {
      server = mkOption {
        type = types.str;
        description = "Target xray server IP or hostname";
      };

      reality = opts.mkRealityClientOptions { };

      vlessTcp = opts.mkVlessTcpOptions { includeConnection = false; };
      vlessGrpc = opts.mkVlessGrpcOptions { includeConnection = false; };
      vlessXhttp = opts.mkVlessXhttpOptions { includeConnection = false; };
    };

    # Relay's own inbound SNIs (for nginx SNI routing on this server)
    vlessTcp.sni = mkOption {
      type = types.str;
      description = "SNI for relay TCP inbound (must differ from server's TCP SNI)";
    };

    vlessGrpc.sni = mkOption {
      type = types.str;
      description = "SNI for relay gRPC inbound (must differ from server's gRPC SNI)";
    };

    vlessXhttp.sni = mkOption {
      type = types.str;
      description = "SNI for relay xHTTP inbound (must differ from server's xHTTP SNI)";
    };
  };

  config = mkIf (config.roles.xray.enable && cfg.enable) {
    assertions = [
      {
        assertion = config.roles.xray.server.enable;
        message = "roles.xray.relay requires roles.xray.server to be enabled";
      }
      {
        assertion = tcpEnabled || grpcEnabled || xhttpEnabled;
        message = "At least one relay transport must be enabled (and matching server transport must also be enabled)";
      }
    ];

    roles.xray._relayConfig = relayConfig;
  };
}
```

- [ ] **Step 2: Commit**

```bash
git add roles/network/xray/relay.nix
git commit -m "feat(xray): add relay module with fwd inbounds, target outbounds, leastPing balancer"
```

---

### Task 5: Create `default.nix` — coordinator

**Files:**
- Create: `roles/network/xray/default.nix`

Imports sub-modules, defines `roles.xray.enable` and internal config options, merges fragments, owns systemd/nginx/firewall.

- [ ] **Step 1: Create `default.nix`**

```nix
# roles/network/xray/default.nix
#
# Coordinator: imports server/client/relay sub-modules, merges their config
# fragments, and owns systemd, nginx, and firewall configuration.
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.roles.xray;

  emptyConfig = {
    inbounds = [ ];
    outbounds = [ ];
    routing = {
      rules = [ ];
      balancers = [ ];
    };
    nginxSniEntries = [ ];
  };

  serverConfig = if cfg.server.enable then cfg._serverConfig else emptyConfig;
  relayConfig = if cfg.relay.enable then cfg._relayConfig else emptyConfig;

  allNginxEntries = serverConfig.nginxSniEntries ++ relayConfig.nginxSniEntries;

  xrayConfigTemplate = {
    log = {
      loglevel = "info";
    };
    inbounds = serverConfig.inbounds ++ relayConfig.inbounds;
    outbounds = serverConfig.outbounds ++ relayConfig.outbounds;
    routing = {
      rules = serverConfig.routing.rules ++ relayConfig.routing.rules;
      balancers = serverConfig.routing.balancers ++ relayConfig.routing.balancers;
    };
  };

  configTemplateFile = pkgs.writeText "xray-config-template.json" (
    builtins.toJSON xrayConfigTemplate
  );
in
{
  imports = [
    ./server.nix
    ./client.nix
    ./relay.nix
  ];

  options.roles.xray = {
    enable = mkEnableOption "xray proxy";

    _serverConfig = mkOption {
      type = types.attrs;
      internal = true;
      default = emptyConfig;
      description = "Config fragment exported by server.nix";
    };

    _relayConfig = mkOption {
      type = types.attrs;
      internal = true;
      default = emptyConfig;
      description = "Config fragment exported by relay.nix";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.server.enable || cfg.client.enable;
        message = "roles.xray requires at least server or client to be enabled";
      }
      {
        assertion = !(cfg.server.enable && cfg.client.enable);
        message = "roles.xray.server and roles.xray.client cannot be enabled on the same host";
      }
    ];

    # Server/relay: systemd service, nginx, firewall
    # (only when server is enabled; client uses services.xray independently)
    services.nginx = mkIf cfg.server.enable {
      enable = true;
      streamConfig =
        let
          defaultPort =
            if allNginxEntries != [ ] then (builtins.head allNginxEntries).port else 9000;
        in
        ''
          map $ssl_preread_server_name $xray_backend {
          ${
            lib.concatMapStrings (
              t: "    ${t.sni}  127.0.0.1:${toString t.port};\n"
            ) allNginxEntries
          }    default  127.0.0.1:${toString defaultPort};
          }

          server {
            listen 443;
            ssl_preread on;
            proxy_pass $xray_backend;
            proxy_protocol on;
          }
        '';
    };

    systemd.services.xray = mkIf cfg.server.enable {
      description = "Xray Reality Daemon";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      path = [
        pkgs.xray
        pkgs.jq
      ];
      serviceConfig = {
        PrivateTmp = true;
        LoadCredential = "private-key:${cfg.server.reality.privateKeyFile}";
        DynamicUser = true;
        CapabilityBoundingSet = "CAP_NET_ADMIN CAP_NET_BIND_SERVICE";
        AmbientCapabilities = "CAP_NET_ADMIN CAP_NET_BIND_SERVICE";
        NoNewPrivileges = true;
      };
      script = ''
        cat ${configTemplateFile} \
          | jq --arg key "$(cat "$CREDENTIALS_DIRECTORY/private-key")" \
              '.inbounds[].streamSettings.realitySettings.privateKey = $key' \
          > /tmp/xray.json
        exec xray -config /tmp/xray.json
      '';
    };

    networking.firewall.allowedTCPPorts = mkIf cfg.server.enable [ 443 ];
  };
}
```

- [ ] **Step 2: Commit**

```bash
git add roles/network/xray/default.nix
git commit -m "feat(xray): add coordinator default.nix merging server+relay configs"
```

---

### Task 6: Migrate host configs — veles and buyan

**Files:**
- Modify: `machines/veles/default.nix`
- Modify: `machines/buyan/default.nix`

Update imports and option paths from `roles.xray-server` to `roles.xray.server`.

- [ ] **Step 1: Update `machines/veles/default.nix`**

Change the import from:
```nix
    ../../roles/network/xray/server.nix
```
to:
```nix
    ../../roles/network/xray
```

Change the config from:
```nix
  roles.xray-server = {
    enable = true;
    reality.privateKeyFile = "/etc/nixos/secrets/xray-reality-private-key";
    vlessTcp = {
      enable = true;
      sni = "api.oneme.ru";
    };
    vlessGrpc = {
      enable = true;
      sni = "avatars.mds.yandex.net";
    };
    vlessXhttp = {
      enable = true;
      sni = "onlymir.ru";
    };
  };
```
to:
```nix
  roles.xray = {
    enable = true;
    server = {
      enable = true;
      reality.privateKeyFile = "/etc/nixos/secrets/xray-reality-private-key";
      vlessTcp = {
        enable = true;
        sni = "api.oneme.ru";
      };
      vlessGrpc = {
        enable = true;
        sni = "avatars.mds.yandex.net";
      };
      vlessXhttp = {
        enable = true;
        sni = "onlymir.ru";
      };
    };
  };
```

- [ ] **Step 2: Update `machines/buyan/default.nix`**

Change the import from:
```nix
    ../../roles/network/xray/server.nix
```
to:
```nix
    ../../roles/network/xray
```

Change the config from:
```nix
  roles.xray-server = {
    enable = true;
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
```
to:
```nix
  roles.xray = {
    enable = true;
    server = {
      enable = true;
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
```

- [ ] **Step 3: Commit**

```bash
git add machines/veles/default.nix machines/buyan/default.nix
git commit -m "refactor(xray): migrate veles and buyan to roles.xray.server"
```

---

### Task 7: Validate with `nix flake check`

**Files:** None (validation only)

- [ ] **Step 1: Format all changed files**

```bash
make fmt
```

- [ ] **Step 2: Run flake check**

```bash
make check
```

Expected: All NixOS configurations (veles, buyan, mokosh, nixpi) evaluate successfully. mokosh and nixpi don't use xray so they should be unaffected.

- [ ] **Step 3: Commit any formatting changes**

```bash
git add -A
git commit -m "style: format xray modules"
```

Note: `make check` requires `secrets/secrets.json` to exist. If it's missing (encrypted), run `make setup-dummy-secrets` first to create a dummy version, or `make unlock-json` if you have the GPG key.

---

### Task 8: (Optional) Add relay config to veles

This task is optional — it configures the actual relay on veles pointing to buyan. The user will need to fill in actual secret values (publicKey, shortId, SNI domains).

**Files:**
- Modify: `machines/veles/default.nix`

- [ ] **Step 1: Add relay config to veles**

Add inside the existing `roles.xray` block:

```nix
    relay = {
      enable = true;
      user = (import ../../secrets).singBoxUsers.someUser;  # replace with actual user
      target = {
        server = (import ../../secrets).ip.buyan.address;
        reality = {
          enable = true;
          publicKey = "...";   # buyan's Reality public key
          shortId = "...";     # authorized shortId
        };
        vlessTcp = {
          enable = true;
          serverName = "ghcr.io";
        };
        vlessGrpc = {
          enable = true;
          serverName = "update.googleapis.com";
        };
        vlessXhttp = {
          enable = true;
          serverName = "dl.google.com";
        };
      };
      vlessTcp.sni = "...";    # relay-specific SNI for TCP
      vlessGrpc.sni = "...";   # relay-specific SNI for gRPC
      vlessXhttp.sni = "...";  # relay-specific SNI for xHTTP
    };
```

- [ ] **Step 2: Run validation**

```bash
make fmt && make check
```

- [ ] **Step 3: Commit**

```bash
git add machines/veles/default.nix
git commit -m "feat(veles): enable xray relay to buyan"
```
