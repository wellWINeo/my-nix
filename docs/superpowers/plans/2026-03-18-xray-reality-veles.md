# Xray Reality on Veles — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform existing xray server/client NixOS modules to use Reality TLS with Vision flow, add xHTTP transport, and wire up veles to use them with `api.oneme.ru` as the fake SNI.

**Architecture:** Single VLESS+Reality inbound on port 443 handles direct TCP+Vision connections; WS/gRPC/xHTTP transports are routed via Xray's path-based VLESS fallback mechanism to localhost sub-inbounds. Private key is injected at NixOS activation time via a shell script — never written to the Nix store. Client module gains a shared Reality option block and two new transports (xHTTP and direct TCP+Vision).

**Tech Stack:** NixOS modules, xray-core (nixpkgs `xray` package), `jq` for JSON transformation, `system.activationScripts` for runtime key injection.

---

## Key Facts for Implementer

**Project layout:**
- `roles/network/xray/server.nix` — xray server NixOS module
- `roles/network/xray/client.nix` — xray client NixOS module
- `machines/veles/default.nix` — veles host config
- `secrets/default.nix` — exports `builtins.fromJSON (builtins.readFile ./secrets.json)` directly

**NixOS xray module API** (from nixpkgs source):
- `services.xray.enable = true`
- `services.xray.settings = <attrset>` — written to Nix store JSON (also runs `xray -test` checkPhase — do NOT use for template with placeholder)
- `services.xray.settingsFile = <path>` — path to config file; used as `LoadCredential = "config.json:${settingsFile}"` and read via `$CREDENTIALS_DIRECTORY/config.json`
- The two options are mutually exclusive
- Service runs with `DynamicUser = true`, `CAP_NET_BIND_SERVICE` for port 443

**Existing secrets pattern:** `secrets = import ../../../secrets;` then `secrets.someField`

**Code style:** nixfmt-rfc-style, `with lib;` at top, `cfg = config.roles.<name>`, `mkIf cfg.enable { ... }`

**Validation:** `nix flake check 'path:.'` — no automated tests, validation is eval-time only. The `nix flake check` will fail if xray settings has a `__XRAY_PRIVATE_KEY__` placeholder and `services.xray.settings` is used (because the module runs `xray -test` on it). That's why we use `settingsFile` for the server.

**Private key injection approach:**
1. Generate a template JSON (Nix store) using `pkgs.writeText` with placeholder `"__XRAY_PRIVATE_KEY__"` in `realitySettings.privateKey`
2. In `system.activationScripts.xray-config`, use `jq` to substitute the placeholder with the real key from disk
3. Write result to `/etc/xray/config.json` (mode 600, root:root)
4. Set `services.xray.settingsFile = "/etc/xray/config.json"`
5. The activation script runs on every `nixos-rebuild switch`, so the file is always current

**Why activation script over ExecStartPre (spec divergence):** The spec suggested using `ExecStartPre` with `/run/xray/config.json`. The `system.activationScripts` approach is used instead because it is simpler: the NixOS xray module's `LoadCredential` mechanism needs a stable path at build time, and the activation script runs before services start on `nixos-rebuild switch`. Trade-off: `/etc/xray/config.json` persists across reboots; if the private key file is missing during a subsequent activation, the file keeps its last good content. `/run/xray/` would be cleared on reboot, which is safer for secret hygiene. The persistent `/etc/` approach is chosen for simplicity.

**gRPC fallback note:** Xray fallback path matching is prefix-based. A gRPC call to service `vl-grpc` sends HTTP/2 path `/vl-grpc/Tun`, which matches fallback path `/vl-grpc`. This is the expected behavior per Xray docs.

---

## Chunk 1: Server Module Rewrite

### Task 1: Rewrite `roles/network/xray/server.nix`

**Files:**
- Modify: `roles/network/xray/server.nix`

Replace the entire file with the Reality-based implementation.

- [ ] **Step 1: Write the new server module**

Replace the entire content of `roles/network/xray/server.nix`:

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

  vlessWsPort = 9000;
  vlessGrpcPort = 9001;
  vlessXhttpPort = 9002;

  # Template config with placeholder for private key.
  # Uses services.xray.settingsFile (not .settings) to avoid the
  # xray -test checkPhase which would reject the placeholder.
  xrayConfigTemplate = {
    log = {
      loglevel = "info";
    };

    inbounds =
      [
        # Main inbound: VLESS + Reality on port 443.
        # Handles direct TCP+Vision connections; fallbacks route
        # WS/gRPC/xHTTP to internal sub-inbounds.
        {
          port = 443;
          protocol = "vless";
          tag = "vless-reality-in";
          settings = {
            clients = map (u: {
              id = u.uuid;
              flow = "xtls-rprx-vision";
              email = "${u.name}@xray";
            }) secrets.singBoxUsers;
            decryption = "none";
            fallbacks =
              lib.optionals cfg.vlessWs.enable [
                {
                  path = cfg.vlessWs.path;
                  dest = vlessWsPort;
                  xver = 1;
                }
              ]
              ++ lib.optionals cfg.vlessGrpc.enable [
                {
                  path = "/${cfg.vlessGrpc.serviceName}";
                  dest = vlessGrpcPort;
                  xver = 1;
                }
              ]
              ++ lib.optionals cfg.vlessXhttp.enable [
                {
                  path = cfg.vlessXhttp.path;
                  dest = vlessXhttpPort;
                  xver = 1;
                }
              ];
          };
          streamSettings = {
            network = "tcp";
            security = "reality";
            realitySettings = {
              target = "${cfg.reality.fakeSni}:443";
              serverNames = [ cfg.reality.fakeSni ];
              # Placeholder replaced at activation time by system.activationScripts.xray-config
              privateKey = "__XRAY_PRIVATE_KEY__";
              # `or []` provides a safe default if the field doesn't exist yet in secrets.json,
              # preventing evaluation failures on hosts that import this module but haven't
              # deployed secrets yet. The server will simply reject all shortIds (no access)
              # until the real secrets are in place.
              shortIds = secrets.xrayRealityShortIds or [ ];
            };
          };
        }
      ]
      # Internal WS sub-inbound (only created when vlessWs is enabled)
      ++ lib.optionals cfg.vlessWs.enable [
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
            sockopt = {
              acceptProxyProtocol = true;
            };
          };
        }
      ]
      # Internal gRPC sub-inbound
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
            sockopt = {
              acceptProxyProtocol = true;
            };
          };
        }
      ]
      # Internal xHTTP sub-inbound
      ++ lib.optionals cfg.vlessXhttp.enable [
        {
          listen = "127.0.0.1";
          port = vlessXhttpPort;
          protocol = "vless";
          tag = "vless-xhttp-in";
          settings = {
            clients = map (u: {
              id = u.uuid;
              email = "${u.name}@xray";
            }) secrets.singBoxUsers;
            decryption = "none";
          };
          streamSettings = {
            network = "xhttp";
            security = "none";
            xhttpSettings = {
              path = cfg.vlessXhttp.path;
            };
            sockopt = {
              acceptProxyProtocol = true;
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
          inboundTag =
            [ "vless-reality-in" ]
            ++ lib.optionals cfg.vlessWs.enable [ "vless-ws-in" ]
            ++ lib.optionals cfg.vlessGrpc.enable [ "vless-grpc-in" ]
            ++ lib.optionals cfg.vlessXhttp.enable [ "vless-xhttp-in" ];
          outboundTag = "direct-out";
        }
      ];
    };
  };

  configTemplateFile = pkgs.writeText "xray-config-template.json" (builtins.toJSON xrayConfigTemplate);
in
{
  options.roles.xray-server = {
    enable = mkEnableOption "xray anti-censorship proxy server with Reality";

    reality = {
      privateKeyFile = mkOption {
        type = types.path;
        description = "Path to the Reality private key file on disk (not stored in Nix store)";
        example = "/etc/nixos/secrets/xray-reality-private-key";
      };

      fakeSni = mkOption {
        type = types.str;
        default = "api.oneme.ru";
        description = "Target server to impersonate (fake SNI). Unauthorized connections are forwarded here.";
      };
    };

    vlessWs = {
      enable = mkEnableOption "VLESS over WebSocket";
      path = mkOption {
        type = types.str;
        default = "/vl-ws";
        description = "WebSocket path";
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

    vlessXhttp = {
      enable = mkEnableOption "VLESS over xHTTP";
      path = mkOption {
        type = types.str;
        default = "/vl-xhttp";
        description = "xHTTP path";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = !(lib.hasPrefix "/" cfg.vlessGrpc.serviceName);
        message = "roles.xray-server.vlessGrpc.serviceName must not start with '/'";
      }
    ];

    # Write template to /etc/xray/config.json at activation time,
    # injecting the private key from disk (never stored in Nix store).
    system.activationScripts.xray-config = {
      text = ''
        install -d -m 700 /etc/xray
        key=$(cat ${lib.escapeShellArg (toString cfg.reality.privateKeyFile)})
        ${pkgs.jq}/bin/jq --arg key "$key" \
          '.inbounds[0].streamSettings.realitySettings.privateKey = $key' \
          ${configTemplateFile} > /etc/xray/config.json
        chmod 600 /etc/xray/config.json
        chown root:root /etc/xray/config.json
      '';
      deps = [ ];
    };

    services.xray = {
      enable = true;
      settingsFile = "/etc/xray/config.json";
    };

    networking.firewall.allowedTCPPorts = [ 443 ];
  };
}
```

- [ ] **Step 2: Check flake evaluates**

```bash
cd /Users/o__ni/Code/Git/my-nix
nix flake check 'path:.' 2>&1 | tail -20
```

**Important:** This check does NOT exercise `server.nix` yet because veles doesn't import it until Task 3. Syntax errors in `server.nix` will only surface in Task 3 Step 3. This step only confirms the rest of the flake (mokosh, nixpi) still evaluates cleanly after the file is present on disk.

- [ ] **Step 3: Commit**

```bash
git add roles/network/xray/server.nix
git commit -m "feat(xray): rewrite server module with Reality+Vision, add xHTTP"
```

---

## Chunk 2: Client Module Update

### Task 2: Update `roles/network/xray/client.nix`

**Files:**
- Modify: `roles/network/xray/client.nix`

Add shared Reality option block, xHTTP outbound, and direct TCP+Vision outbound.

- [ ] **Step 1: Write the updated client module**

Replace the entire content of `roles/network/xray/client.nix`:

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

  # Build streamSettings for a given transport type.
  # security is either "tls" or "reality" depending on cfg.reality.enable.
  mkStreamSettings =
    transport:
    let
      securitySettings =
        if cfg.reality.enable then
          {
            security = "reality";
            realitySettings = {
              publicKey = cfg.reality.publicKey;
              shortId = cfg.reality.shortId;
              serverName = cfg.reality.serverName;
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
                    # Vision flow: ONLY set on direct TCP outbound
                    flow = "xtls-rprx-vision";
                    encryption = "none";
                  }
                ];
              }
            ];
          };
          streamSettings = mkStreamSettings {
            server = cfg.vlessTcp.server;
            extra = {
              network = "tcp";
            };
          };
        }
      ]
      ++ lib.optionals cfg.vlessWs.enable [
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
                    # No flow for WS — framed transport, Vision not applicable
                    encryption = "none";
                  }
                ];
              }
            ];
          };
          streamSettings = mkStreamSettings {
            server = cfg.vlessWs.server;
            extra = {
              network = "ws";
              wsSettings = {
                path = cfg.vlessWs.path;
              };
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
            ++ lib.optionals cfg.vlessWs.enable [ "vless-ws-out" ]
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

    # Shared Reality settings — applies to all enabled outbounds when reality.enable = true.
    # When false, outbounds use regular TLS (backwards-compatible with nginx+TLS servers).
    reality = {
      enable = mkEnableOption "Reality TLS for all outbounds";

      publicKey = mkOption {
        type = types.str;
        default = "";
        description = "Server's Reality public key";
      };

      shortId = mkOption {
        type = types.str;
        default = "";
        description = "Authorized shortId for authentication";
      };

      serverName = mkOption {
        type = types.str;
        default = "api.oneme.ru";
        description = "SNI to present during TLS handshake";
      };

      fingerprint = mkOption {
        type = types.str;
        default = "chrome";
        description = "uTLS fingerprint to use (chrome, firefox, safari, etc.)";
      };
    };

    vlessTcp = {
      enable = mkEnableOption "VLESS over direct TCP with Vision flow";

      server = mkOption {
        type = types.str;
        description = "Server domain or IP";
      };

      port = mkOption {
        type = types.port;
        default = 443;
        description = "Server port";
      };

      auth = {
        name = mkOption {
          type = types.str;
          description = "Username (informational only; xray VLESS uses UUID)";
        };
        uuid = mkOption {
          type = types.str;
          description = "UUID for authentication";
        };
      };
    };

    vlessWs = {
      enable = mkEnableOption "VLESS over WebSocket";

      server = mkOption {
        type = types.str;
        description = "Server domain (e.g., gw.uspenskiy.su or veles IP)";
      };

      port = mkOption {
        type = types.port;
        default = 443;
        description = "Server port";
      };

      auth = {
        name = mkOption {
          type = types.str;
          description = "Username (kept for parity; unused in xray VLESS config)";
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
        description = "Server domain";
      };

      port = mkOption {
        type = types.port;
        default = 443;
        description = "Server port";
      };

      auth = {
        name = mkOption {
          type = types.str;
          description = "Username (kept for parity; unused in xray VLESS config)";
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

    vlessXhttp = {
      enable = mkEnableOption "VLESS over xHTTP";

      server = mkOption {
        type = types.str;
        description = "Server domain";
      };

      port = mkOption {
        type = types.port;
        default = 443;
        description = "Server port";
      };

      auth = {
        name = mkOption {
          type = types.str;
          description = "Username (informational only)";
        };
        uuid = mkOption {
          type = types.str;
          description = "UUID for authentication";
        };
      };

      path = mkOption {
        type = types.str;
        default = "/vl-xhttp";
        description = "xHTTP path";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion =
          cfg.vlessTcp.enable || cfg.vlessWs.enable || cfg.vlessGrpc.enable || cfg.vlessXhttp.enable;
        message = "At least one xray-client outbound must be enabled";
      }
      {
        assertion =
          !cfg.reality.enable
          || (cfg.reality.publicKey != "" && cfg.reality.shortId != "" && cfg.reality.serverName != "");
        message = "roles.xray-client.reality.publicKey, shortId, and serverName must be set when reality.enable = true";
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

- [ ] **Step 2: Check flake evaluates**

```bash
cd /Users/o__ni/Code/Git/my-nix
nix flake check 'path:.' 2>&1 | tail -20
```

The client module uses `services.xray.settings` (attrset), so nixpkgs runs `xray -test` on the generated config at build time. The Reality publicKey/shortId/serverName options all have safe defaults (`""` or `"api.oneme.ru"`) that will produce a valid (if non-functional) xray config — `xray -test` only checks JSON structure, not semantic correctness. **Note:** This check only exercises the client module if nixpi (or another host) imports it; if no host imports the client module, errors only surface when it is wired up.

- [ ] **Step 3: Commit**

```bash
git add roles/network/xray/client.nix
git commit -m "feat(xray): add Reality support, xHTTP and TCP+Vision outbounds to client"
```

---

## Chunk 3: Veles Machine Config

### Task 3: Wire up xray server in `machines/veles/default.nix`

**Files:**
- Modify: `machines/veles/default.nix`

- [ ] **Step 1: Update veles machine config**

Replace the contents of `machines/veles/default.nix`:

```nix
{
  ...
}:

let
  hostname = "veles";
  domainName = "uspenskiy.su";
in
{
  imports = [
    ../../common/hardened.nix
    ../../common/server.nix
    ../../hardware/vm.nix
    ../../roles/network/stream-forwarder.nix
    ../../roles/network/xray/server.nix
  ];

  boot.loader.grub.device = "/dev/sda";

  # disk layout
  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/NIXOS";
      fsType = "ext4";
    };
  };

  swapDevices = [
    {
      device = "/.swapfile";
      size = 4 * 1024; # 4GiB
    }
  ];

  # network
  networking = {
    hostName = hostname;
    useDHCP = true;
    nameservers = [
      "1.1.1.1"
      "1.0.0.1"
    ];
    firewall.enable = true;
  };

  services.qemuGuest.enable = true;
  services.spice-vdagentd.enable = true;

  services.openssh.settings = {
    PermitRootLogin = "no";
    PasswordAuthentication = false;
  };

  ###
  # Roles
  ###
  roles.hardened.enable = true;

  roles.stream-forwarder = {
    enable = true;
    forwards = [
      {
        listenAddress = "0.0.0.0:8443";
        targetAddress = "93.183.127.202:443";
      }
    ];
  };

  roles.xray-server = {
    enable = true;
    reality = {
      privateKeyFile = "/etc/nixos/secrets/xray-reality-private-key";
      fakeSni = "api.oneme.ru";
    };
    vlessWs.enable = true;
    vlessGrpc.enable = true;
    vlessXhttp.enable = true;
  };

  system.stateVersion = "25.11";
}
```

Note: `roles.letsencrypt` is removed — Reality does not use ACME certificates.

- [ ] **Step 2: Verify secrets for flake check**

The server module reads `secrets.xrayRealityShortIds or []`. Thanks to the `or []` default, the flake check will **not** fail even if `xrayRealityShortIds` is missing from `secrets.json` — it falls back to an empty list. No action needed for the check to pass.

Note: `xrayRealityPublicKey` is for future client configurations (nixpi) and is **not** consumed by the server module or the veles config. Do not add it to secrets.json at this stage unless you are also configuring clients.

- [ ] **Step 3: Check flake evaluates**

```bash
cd /Users/o__ni/Code/Git/my-nix
nix flake check 'path:.' --all-systems 2>&1 | tail -30
```

If the check fails due to missing `xrayRealityShortIds` in secrets, that's expected — the secrets file needs to be updated on deploy. If there are Nix evaluation errors, fix them.

- [ ] **Step 4: Format all modified files**

```bash
cd /Users/o__ni/Code/Git/my-nix
nixfmt roles/network/xray/server.nix roles/network/xray/client.nix machines/veles/default.nix
```

- [ ] **Step 5: Run flake check after formatting**

```bash
nix flake check 'path:.' --all-systems 2>&1 | tail -20
```

- [ ] **Step 6: Commit**

```bash
git add machines/veles/default.nix roles/network/xray/server.nix roles/network/xray/client.nix
git commit -m "feat(veles): enable xray Reality server with WS, gRPC, xHTTP transports"
```

---

## Post-Implementation Notes

**Before deploying to veles (manual steps):**
1. Generate Reality keypair: `xray x25519` on veles
2. Add to `secrets/secrets.json`: `"xrayRealityPublicKey": "<pubkey>"`, `"xrayRealityShortIds": ["<shortid1>"]`
3. Save private key to `/etc/nixos/secrets/xray-reality-private-key` on veles (mode 600)
4. Run `make lock` to re-encrypt secrets
5. Deploy: `make switch` (or `nixos-rebuild switch --flake .#veles` on veles)

**Verifying after deploy:**
```bash
systemctl status xray
cat /etc/xray/config.json | jq .inbounds[0].streamSettings.realitySettings.privateKey
# Should NOT show __XRAY_PRIVATE_KEY__ — should show the real key
```
