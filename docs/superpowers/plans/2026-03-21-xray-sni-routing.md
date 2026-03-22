# Xray SNI-Based Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace xray's broken single-inbound+fallbacks architecture with nginx `ssl_preread` SNI routing to three independent Reality inbounds, fixing gRPC and xHTTP connectivity.

**Architecture:** nginx listens on port 443 in stream mode with `ssl_preread`, reads the TLS SNI from the ClientHello, and routes the raw TCP connection to one of three xray inbounds on localhost (9000-9002). Each xray inbound directly handles one transport (TCP+Vision, gRPC, xHTTP) with its own Reality TLS config and matching camouflage target.

**Tech Stack:** NixOS, xray-core, nginx stream module with ssl_preread

**Spec:** `docs/superpowers/specs/2026-03-21-xray-sni-routing-design.md`

---

### Task 1: Rewrite server options

**Files:**
- Modify: `roles/network/xray/server.nix:181-224` (options block)

- [ ] **Step 1: Replace `reality.fakeSni` with `vlessTcp.enable` and per-transport `sni` options; remove `vlessWs`**

Replace the entire options block (lines 181-224) with:

```nix
  options.roles.xray-server = {
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
```

- [ ] **Step 2: Verify syntax**

Run: `nix-instantiate --parse roles/network/xray/server.nix`
Expected: successful parse (may have eval errors since we haven't updated the rest yet)

---

### Task 2: Rewrite server let-bindings and inbounds

**Files:**
- Modify: `roles/network/xray/server.nix:10-178` (let block: ports, clients, xrayConfigTemplate, configTemplateFile)

- [ ] **Step 1: Replace port names and remove `vlessClients` separation**

Replace lines 14-22 with:

```nix
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

  # Shared Reality settings (privateKey injected at runtime)
  mkRealitySettings = sni: {
    target = "${sni}:443";
    serverNames = [ sni ];
    shortIds = secrets.xray.reality.shortIds or [ ];
  };
```

- [ ] **Step 2: Replace the entire xrayConfigTemplate inbounds with three direct Reality inbounds**

Replace lines 27-174 (the entire `xrayConfigTemplate`) with:

```nix
  xrayConfigTemplate = {
    log = {
      loglevel = "info";
    };

    inbounds =
      # TCP + Vision + Reality
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
          };
        }
      ]
      # gRPC + Reality
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
            realitySettings = mkRealitySettings cfg.vlessGrpc.sni;
            grpcSettings = {
              serviceName = cfg.vlessGrpc.serviceName;
            };
          };
        }
      ]
      # xHTTP + Reality
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
    };
  };
```

- [ ] **Step 3: Verify syntax**

Run: `nix-instantiate --parse roles/network/xray/server.nix`
Expected: successful parse

---

### Task 3: Rewrite server config block (assertions, systemd, nginx)

**Files:**
- Modify: `roles/network/xray/server.nix:226-273` (config block)

- [ ] **Step 1: Replace the entire config block**

Replace lines 226-272 with:

```nix
  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = !(lib.hasPrefix "/" cfg.vlessGrpc.serviceName);
        message = "roles.xray-server.vlessGrpc.serviceName must not start with '/'";
      }
      {
        assertion = (secrets.xray.reality.shortIds or [ ]) != [ ];
        message = "secrets.xray.reality.shortIds must be set before deploying xray-server (add to secrets.json and run make lock)";
      }
      {
        assertion = cfg.vlessTcp.enable || cfg.vlessGrpc.enable || cfg.vlessXhttp.enable;
        message = "At least one xray-server transport must be enabled";
      }
    ];

    # nginx SNI routing: L4 proxy that reads TLS SNI and routes to
    # the correct xray inbound. Never terminates TLS.
    services.nginx = {
      enable = true;
      streamConfig =
        let
          enabledTransports =
            lib.optionals cfg.vlessTcp.enable [{ sni = cfg.vlessTcp.sni; port = vlessTcpPort; }]
            ++ lib.optionals cfg.vlessGrpc.enable [{ sni = cfg.vlessGrpc.sni; port = vlessGrpcPort; }]
            ++ lib.optionals cfg.vlessXhttp.enable [{ sni = cfg.vlessXhttp.sni; port = vlessXhttpPort; }];
          defaultPort = if cfg.vlessTcp.enable then vlessTcpPort
                        else (builtins.head enabledTransports).port;
        in ''
          map $ssl_preread_server_name $xray_backend {
          ${lib.concatMapStrings (t: "    ${t.sni}  127.0.0.1:${toString t.port};\n") enabledTransports}    default  127.0.0.1:${toString defaultPort};
          }

          server {
            listen 443;
            ssl_preread on;
            proxy_pass $xray_backend;
          }
        '';
    };

    systemd.services.xray = {
      description = "Xray Reality Daemon";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      path = [
        pkgs.xray
        pkgs.jq
      ];
      serviceConfig = {
        PrivateTmp = true;
        LoadCredential = "private-key:${cfg.reality.privateKeyFile}";
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

    networking.firewall.allowedTCPPorts = [ 443 ];
  };
```

- [ ] **Step 2: Verify full file parses**

Run: `nix-instantiate --parse roles/network/xray/server.nix`
Expected: successful parse

- [ ] **Step 3: Commit server.nix**

```bash
git add roles/network/xray/server.nix
git commit -m "refactor(xray/server): replace fallbacks with nginx SNI routing

Replace single-inbound+fallbacks architecture with nginx ssl_preread
SNI routing to three independent Reality inbounds. Each transport
(TCP+Vision, gRPC, xHTTP) gets its own Reality config with matching
camouflage target. Removes WS transport."
```

---

### Task 4: Update client module

**Files:**
- Modify: `roles/network/xray/client.nix`

- [ ] **Step 1: Add per-transport `serverName` option and update `mkStreamSettings`**

In the `let` block, update `mkStreamSettings` (lines 18-42) to accept transport-level `serverName`:

```nix
  mkStreamSettings =
    transport:
    let
      sni =
        if (transport.serverName or "") != "" then
          transport.serverName
        else
          cfg.reality.serverName;
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
```

- [ ] **Step 2: Remove the entire `vlessWs` outbound block (lines 92-121) and its options (lines 284-315)**

Delete the WS outbound from `xrayConfig.outbounds` (lines 92-121).

Delete the `vlessWs` options block (lines 284-315).

- [ ] **Step 3: Remove `vlessWs` from balancer selector and assertion**

In the balancer selector (line 201), remove:
```nix
            ++ lib.optionals cfg.vlessWs.enable [ "vless-ws-out" ]
```

In the assertion (line 388), remove `cfg.vlessWs.enable ||`.

- [ ] **Step 4: Add `serverName` option to each transport**

Add to `vlessTcp` options (after line 281):
```nix
      serverName = mkOption {
        type = types.str;
        default = "";
        description = "Reality SNI for this transport (overrides shared reality.serverName)";
      };
```

Add the same option to `vlessGrpc` (after line 347) and `vlessXhttp` (after line 380).

- [ ] **Step 5: Fix gRPC serviceName default**

Change line 345 from:
```nix
        default = "vl-grpc";
```
to:
```nix
        default = "VlGrpc";
```

- [ ] **Step 6: Pass `serverName` through mkStreamSettings calls**

Update each `mkStreamSettings` call to include `serverName`. For example, the TCP call (lines 84-89):

```nix
          streamSettings = mkStreamSettings {
            server = cfg.vlessTcp.server;
            serverName = cfg.vlessTcp.serverName;
            extra = {
              network = "tcp";
            };
          };
```

Same for gRPC (lines 140-148) and xHTTP (lines 169-177): add `serverName = cfg.vlessGrpc.serverName;` and `serverName = cfg.vlessXhttp.serverName;` respectively.

- [ ] **Step 7: Verify syntax**

Run: `nix-instantiate --parse roles/network/xray/client.nix`
Expected: successful parse

- [ ] **Step 8: Commit client.nix**

```bash
git add roles/network/xray/client.nix
git commit -m "refactor(xray/client): per-transport Reality SNI, remove WS, fix gRPC serviceName

Add serverName option to each transport for per-SNI Reality config.
Remove vlessWs transport. Fix vlessGrpc.serviceName default from
'vl-grpc' to 'VlGrpc' to match server."
```

---

### Task 5: Update veles machine config

**Files:**
- Modify: `machines/veles/default.nix:58-67`

- [ ] **Step 1: Replace xray-server config**

Replace lines 58-67 with:

```nix
  roles.xray-server = {
    enable = true;
    reality.privateKeyFile = "/etc/nixos/secrets/veles-xray-reality.privkey";
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

- [ ] **Step 2: Commit veles config**

```bash
git add machines/veles/default.nix
git commit -m "chore(veles): configure SNI-based xray routing

Assign per-transport SNIs: api.oneme.ru (TCP), avatars.mds.yandex.net
(gRPC), onlymir.ru (xHTTP). Remove WS and fakeSni."
```

---

### Task 6: Evaluate and verify

- [ ] **Step 1: Run nix flake check**

Run: `nix flake check 'path:.' --all-systems`
Expected: no errors. If there are eval errors, fix them before proceeding.

- [ ] **Step 2: Inspect the generated xray config template**

Run: `nix eval --json '.#nixosConfigurations.veles.config.systemd.services.xray.script' 2>/dev/null || echo "Try: nix build .#nixosConfigurations.veles.config.system.build.toplevel --dry-run"`

Verify:
- Three inbounds on 127.0.0.1:9000-9002
- Each has `security: "reality"` with its own `serverNames` and `target`
- No fallbacks anywhere
- jq uses `inbounds[]` (not `inbounds[0]`)

- [ ] **Step 3: Inspect the generated nginx streamConfig**

Verify the nginx config contains:
- `map $ssl_preread_server_name $xray_backend` with all three SNIs
- `server { listen 443; ssl_preread on; proxy_pass $xray_backend; }`

- [ ] **Step 4: Commit any fixes**

If any eval issues required fixes, commit them:
```bash
git add -u
git commit -m "fix(xray): address eval errors from SNI routing migration"
```
