# Xray NixOS Module Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create xray-core NixOS modules (server + client) that mirror the existing sing-box module structure, enabling evaluation of xray as a potential sing-box replacement.

**Architecture:** Two independent NixOS modules (`roles.xray-server` and `roles.xray-client`) that generate xray-core JSON configuration. Server listens on localhost with nginx reverse proxy for TLS termination (same pattern as sing-box). Client provides SOCKS5 inbound with VLESS-WS and VLESS-gRPC outbounds. Both reuse `secrets.singBoxUsers` for credentials.

**Tech Stack:** NixOS modules, xray-core (nixpkgs `xray` package), nginx, JSON config generation via `builtins.toJSON`

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `roles/network/xray/server.nix` | Create | Xray server module: options, config generation, nginx integration |
| `roles/network/xray/client.nix` | Create | Xray client module: options, SOCKS5 inbound, VLESS outbounds |

No existing files are modified. The modules are designed to be deployed on a separate host from sing-box.

---

## Chunk 1: Server Module

### Task 1: Create xray server module options

**Files:**
- Create: `roles/network/xray/server.nix`

- [ ] **Step 1: Create the module file with options only**

Create `roles/network/xray/server.nix` with module options mirroring `roles/network/sing-box/server.nix`. No `naive` option (xray doesn't support NaiveProxy).

```nix
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.roles.xray-server;
  secrets = import ../../../secrets;
in
{
  options.roles.xray-server = {
    enable = mkEnableOption "xray anti-censorship proxy server";

    baseDomain = mkOption {
      type = types.str;
      description = "Base domain for certificates and hostnames";
    };

    vlessWs = {
      enable = mkEnableOption "VLESS over WebSocket";
      path = mkOption {
        type = types.str;
        default = "/vl-ws";
      };
    };

    vlessGrpc = {
      enable = mkEnableOption "VLESS over gRPC";
      serviceName = mkOption {
        type = types.str;
        default = "vl-grpc";
        description = "gRPC service name (no leading slash)";
      };
    };

    enableFallback = mkEnableOption "Enable fallback redirect";
  };
}
```

- [ ] **Step 2: Commit options scaffold**

```bash
git add roles/network/xray/server.nix
git commit -m "feat(xray): add server module options scaffold"
```

### Task 2: Add xray server config generation

**Files:**
- Modify: `roles/network/xray/server.nix`

- [ ] **Step 1: Add xray JSON config generation**

Add the `xrayConfig` let-binding and `config` section. Key differences from sing-box:
- xray uses `protocol` field instead of `type`
- xray uses `settings.clients` with `id` field (not `users` with `uuid`)
- xray uses `streamSettings` with `network`/`wsSettings`/`grpcSettings` (not `transport`)
- xray uses `"freedom"` outbound protocol (not `"direct"`)
- xray uses `decryption = "none"` for VLESS inbounds
- No TLS on inbounds (nginx handles it), so `security = "none"`

```nix
  vlessWsPort = 9000;
  vlessGrpcPort = 9001;

  xrayConfig = {
    log = {
      loglevel = "info";
    };

    inbounds =
      lib.optionals cfg.vlessWs.enable [
        {
          listen = "127.0.0.1";
          port = vlessWsPort;
          protocol = "vless";
          tag = "vless-ws-in";
          settings = {
            clients = map (u: {
              id = u.uuid;
              email = "${u.name}@xray";
            }) secrets.singBoxUsers;
            decryption = "none";
          };
          streamSettings = {
            network = "ws";
            security = "none";
            wsSettings = {
              path = cfg.vlessWs.path;
            };
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
            clients = map (u: {
              id = u.uuid;
              email = "${u.name}@xray";
            }) secrets.singBoxUsers;
            decryption = "none";
          };
          streamSettings = {
            network = "grpc";
            security = "none";
            grpcSettings = {
              serviceName = cfg.vlessGrpc.serviceName;
            };
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
          inboundTag = lib.optionals cfg.vlessWs.enable [ "vless-ws-in" ]
            ++ lib.optionals cfg.vlessGrpc.enable [ "vless-grpc-in" ];
          outboundTag = "direct-out";
        }
      ];
    };
  };
```

- [ ] **Step 2: Add the config section with assertions and xray service**

```nix
  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.vlessWs.enable || cfg.vlessGrpc.enable;
        message = "At least one xray inbound must be enabled";
      }
    ];

    services.xray = {
      enable = true;
      settings = xrayConfig;
    };
  };
```

- [ ] **Step 3: Commit config generation**

```bash
git add roles/network/xray/server.nix
git commit -m "feat(xray): add server config generation with VLESS-WS and VLESS-gRPC"
```

### Task 3: Add nginx integration to xray server

**Files:**
- Modify: `roles/network/xray/server.nix`

- [ ] **Step 1: Add nginx virtual host configuration**

Add to the `config` section, identical pattern to sing-box server:

```nix
    services.nginx = mkIf (cfg.vlessWs.enable || cfg.vlessGrpc.enable) {
      enable = true;

      virtualHosts."gw.${cfg.baseDomain}" = {
        http2 = true;
        forceSSL = true;
        enableACME = false;

        sslCertificate = "/var/lib/acme/${cfg.baseDomain}/fullchain.pem";
        sslCertificateKey = "/var/lib/acme/${cfg.baseDomain}/key.pem";

        locations.${cfg.vlessWs.path} = mkIf cfg.vlessWs.enable {
          proxyPass = "http://127.0.0.1:${toString vlessWsPort}";
          proxyWebsockets = true;
          recommendedProxySettings = true;
        };

        locations."/${cfg.vlessGrpc.serviceName}" = mkIf cfg.vlessGrpc.enable {
          extraConfig = ''
            grpc_pass grpc://127.0.0.1:${toString vlessGrpcPort};
            grpc_set_header Host $host;
            grpc_set_header X-Real-IP $remote_addr;
          '';
        };
        # Note: serviceName default is "vl-grpc" (no leading slash),
        # so this produces location "/vl-grpc" — no double-slash issue.

        locations."/" = mkIf cfg.enableFallback {
          return = "301 https://${cfg.baseDomain}$request_uri";
        };
      };
    };
```

- [ ] **Step 2: Commit nginx integration**

```bash
git add roles/network/xray/server.nix
git commit -m "feat(xray): add nginx reverse proxy for VLESS transports"
```

---

## Chunk 2: Client Module

### Task 4: Create xray client module options

**Files:**
- Create: `roles/network/xray/client.nix`

- [ ] **Step 1: Create client module with options**

Mirror `roles/network/sing-box/client.nix` options exactly:

```nix
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.roles.xray-client;
in
{
  options.roles.xray-client = {
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

    vlessWs = {
      enable = mkEnableOption "VLESS over WebSocket";

      server = mkOption {
        type = types.str;
        description = "Server domain (e.g., gw.uspenskiy.su)";
      };

      port = mkOption {
        type = types.port;
        default = 443;
        description = "Server port";
      };

      auth = {
        name = mkOption {
          type = types.str;
          description = "Username for authentication";
        };

        uuid = mkOption {
          type = types.str;
          description = "UUID for authentication";
        };
      };

      path = mkOption {
        type = types.str;
        default = "/vl-ws";
        description = "WebSocket path";
      };
    };

    vlessGrpc = {
      enable = mkEnableOption "VLESS over gRPC";

      server = mkOption {
        type = types.str;
        description = "Server domain (e.g., gw.uspenskiy.su)";
      };

      port = mkOption {
        type = types.port;
        default = 443;
        description = "Server port";
      };

      auth = {
        name = mkOption {
          type = types.str;
          description = "Username for authentication";
        };

        uuid = mkOption {
          type = types.str;
          description = "UUID for authentication";
        };
      };

      serviceName = mkOption {
        type = types.str;
        default = "vl-grpc";
        description = "gRPC service name (must match server)";
      };
    };
  };

  # Note: auth.name options are kept for sing-box parity but are unused
  # in the xray config — xray VLESS only uses UUID for authentication.
}
```

- [ ] **Step 2: Commit client options scaffold**

```bash
git add roles/network/xray/client.nix
git commit -m "feat(xray): add client module options scaffold"
```

### Task 5: Add xray client config generation

**Files:**
- Modify: `roles/network/xray/client.nix`

- [ ] **Step 1: Add xray client JSON config generation**

Key differences from sing-box client:
- xray uses `protocol = "socks"` with `settings.auth = "noauth"` for SOCKS inbound
- xray uses `protocol = "vless"` with `settings.vnext` array for VLESS outbounds
- xray uses `streamSettings` with `security = "tls"` and `tlsSettings.serverName`
- xray has no built-in `urltest` — use a `balancer` in routing with `"random"` strategy as a basic alternative
- Do NOT set `flow` on VLESS users for WS/gRPC transports — `flow` (e.g., `xtls-rprx-vision`) is only for direct TCP+TLS

```nix
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
      lib.optionals cfg.vlessWs.enable [
        {
          protocol = "vless";
          tag = "vless-ws-out";
          settings = {
            vnext = [
              {
                address = cfg.vlessWs.server;
                port = cfg.vlessWs.port;
                users = [
                  {
                    id = cfg.vlessWs.auth.uuid;
                    encryption = "none";
                  }
                ];
              }
            ];
          };
          streamSettings = {
            network = "ws";
            security = "tls";
            tlsSettings = {
              serverName = cfg.vlessWs.server;
            };
            wsSettings = {
              path = cfg.vlessWs.path;
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
          streamSettings = {
            network = "grpc";
            security = "tls";
            tlsSettings = {
              serverName = cfg.vlessGrpc.server;
            };
            grpcSettings = {
              serviceName = cfg.vlessGrpc.serviceName;
            };
          };
        }
      ]
      # Safety fallback: handles any traffic not matched by balancer
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
            lib.optionals cfg.vlessWs.enable [ "vless-ws-out" ]
            ++ lib.optionals cfg.vlessGrpc.enable [ "vless-grpc-out" ];
          strategy = {
            type = "random";
          };
        }
      ];
    };
  };
```

- [ ] **Step 2: Add config section with assertions and xray service**

```nix
  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.vlessWs.enable || cfg.vlessGrpc.enable;
        message = "At least one xray outbound must be enabled";
      }
    ];

    services.xray = {
      enable = true;
      settings = xrayConfig;
    };

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ];
  };
```

- [ ] **Step 3: Commit client config generation**

```bash
git add roles/network/xray/client.nix
git commit -m "feat(xray): add client config generation with SOCKS5 inbound and VLESS outbounds"
```

---

## Key Config Mapping Reference

This table maps sing-box concepts to their xray equivalents, for the implementing engineer:

| Concept | sing-box | xray |
|---------|----------|------|
| Config field for protocol | `type` | `protocol` |
| VLESS user ID | `users[].uuid` | `settings.clients[].id` (server) / `settings.vnext[].users[].id` (client) |
| Direct outbound | `type = "direct"` | `protocol = "freedom"` |
| SOCKS inbound | `type = "socks"` | `protocol = "socks"` |
| WebSocket transport | `transport = { type = "ws"; path = ...; }` | `streamSettings = { network = "ws"; wsSettings = { path = ...; }; }` |
| gRPC transport | `transport = { type = "grpc"; service_name = ...; }` | `streamSettings = { network = "grpc"; grpcSettings = { serviceName = ...; }; }` |
| TLS config | `tls = { enabled = true; server_name = ...; }` | `streamSettings = { security = "tls"; tlsSettings = { serverName = ...; }; }` |
| Auto-failover | `type = "urltest"` outbound | `routing.balancers` with selector |
| Route final | `route.final = "tag"` | `routing.rules` with explicit match |
| Log level | `log.level` | `log.loglevel` |
| NixOS service | `services.sing-box` | `services.xray` |
