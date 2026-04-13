# MTProxy + SNI Router Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Telegram MTProxy (telemt) to veles in fake-TLS mode, sharing port 443 with xray via a new shared SNI router module.

**Architecture:** Extract nginx stream SNI routing from xray into a reusable `sni-router` module. Create a standalone `mtproxy` module that runs telemt and registers its SNI entry. Refactor xray coordinator to use sni-router instead of owning nginx directly. Add nixpkgs-unstable flake input for the telemt package.

**Tech Stack:** NixOS modules (Nix), nginx stream, telemt (Rust MTProxy), xray

**Spec:** `docs/superpowers/specs/2026-04-13-mtproxy-sni-router-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `roles/network/sni-router.nix` | Create | Shared SNI-based TLS routing via nginx stream |
| `roles/network/mtproxy.nix` | Create | telemt MTProxy systemd service + config generation |
| `roles/network/xray/default.nix` | Modify | Remove nginx/firewall ownership, feed sni-router entries |
| `roles/network/xray/server.nix` | Modify | Remove `nginxSniEntries` from config fragment |
| `roles/network/xray/relay.nix` | Modify | Remove `nginxSniEntries` from config fragment |
| `flake.nix` | Modify | Add nixpkgs-unstable input, pass to veles |
| `machines/veles/default.nix` | Modify | Import mtproxy, configure telemt + sni-router |

---

### Task 1: Create SNI Router Module

**Files:**
- Create: `roles/network/sni-router.nix`

- [ ] **Step 1: Create `roles/network/sni-router.nix`**

```nix
# roles/network/sni-router.nix
#
# Shared SNI-based TLS routing via nginx stream.
# Other modules register entries via roles.sni-router.entries.
{
  config,
  lib,
  ...
}:

with lib;

let
  cfg = config.roles.sni-router;

  defaultBackend =
    if cfg.defaultBackend != null then
      cfg.defaultBackend
    else if cfg.entries != [ ] then
      (builtins.head cfg.entries).backend
    else
      "127.0.0.1:9000";
in
{
  options.roles.sni-router = {
    enable = mkEnableOption "SNI-based TLS routing via nginx stream";

    port = mkOption {
      type = types.port;
      default = 443;
      description = "External port to listen on";
    };

    entries = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            sni = mkOption {
              type = types.str;
              description = "SNI hostname to match";
            };
            backend = mkOption {
              type = types.str;
              description = "Backend address (e.g. 127.0.0.1:9000)";
            };
          };
        }
      );
      default = [ ];
      description = "List of SNI → backend mappings";
    };

    defaultBackend = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Fallback backend; defaults to first entry if null";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.entries != [ ];
        message = "roles.sni-router requires at least one entry";
      }
    ];

    services.nginx = {
      enable = true;
      streamConfig = ''
        map $ssl_preread_server_name $sni_backend {
        ${lib.concatMapStrings (e: "    ${e.sni}  ${e.backend};\n") cfg.entries}    default  ${defaultBackend};
        }

        server {
          listen ${toString cfg.port};
          ssl_preread on;
          proxy_pass $sni_backend;
          proxy_protocol on;
        }
      '';
    };

    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
```

- [ ] **Step 2: Commit**

```bash
git add roles/network/sni-router.nix
git commit -m "feat: add shared sni-router module for nginx stream SNI routing"
```

---

### Task 2: Refactor Xray to Use SNI Router

**Files:**
- Modify: `roles/network/xray/default.nix`
- Modify: `roles/network/xray/server.nix`
- Modify: `roles/network/xray/relay.nix`

- [ ] **Step 1: Remove `nginxSniEntries` from `server.nix`**

In `roles/network/xray/server.nix`, remove the `nginxSniEntries` block from the `serverConfig` let-binding (lines 127–145). The `serverConfig` should end after the `routing` block:

```nix
    # REMOVE this entire block from serverConfig:
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
```

- [ ] **Step 2: Remove `nginxSniEntries` from `relay.nix`**

In `roles/network/xray/relay.nix`, remove the `nginxSniEntries` block from the `relayConfig` let-binding (lines 258–276). The `relayConfig` should end after the `routing` block.

```nix
    # REMOVE this entire block from relayConfig:
    nginxSniEntries =
      lib.optionals tcpInEnabled [
        {
          sni = cfg.vlessTcp.sni;
          port = relayTcpPort;
        }
      ]
      ++ lib.optionals grpcInEnabled [
        {
          sni = cfg.vlessGrpc.sni;
          port = relayGrpcPort;
        }
      ]
      ++ lib.optionals xhttpInEnabled [
        {
          sni = cfg.vlessXhttp.sni;
          port = relayXhttpPort;
        }
      ];
```

- [ ] **Step 3: Refactor `default.nix` — remove nginx/firewall, add sni-router**

Replace the entire `roles/network/xray/default.nix` with:

```nix
# roles/network/xray/default.nix
#
# Coordinator: imports server/client/relay sub-modules, merges their config
# fragments, and owns systemd configuration. SNI routing delegated to sni-router.
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
  };

  serverCfg = config.roles.xray.server;
  relayCfg = config.roles.xray.relay;

  serverConfig = if cfg.server.enable then cfg._serverConfig else emptyConfig;
  relayConfig = if cfg.relay.enable then cfg._relayConfig else emptyConfig;

  # Port constants (must match server.nix / relay.nix)
  vlessTcpPort = 9000;
  vlessGrpcPort = 9001;
  vlessXhttpPort = 9002;
  relayTcpPort = 9010;
  relayGrpcPort = 9011;
  relayXhttpPort = 9012;

  # Build sni-router entries from enabled transports
  serverSniEntries =
    lib.optionals serverCfg.vlessTcp.enable [
      { sni = serverCfg.vlessTcp.sni; backend = "127.0.0.1:${toString vlessTcpPort}"; }
    ]
    ++ lib.optionals serverCfg.vlessGrpc.enable [
      { sni = serverCfg.vlessGrpc.sni; backend = "127.0.0.1:${toString vlessGrpcPort}"; }
    ]
    ++ lib.optionals serverCfg.vlessXhttp.enable [
      { sni = serverCfg.vlessXhttp.sni; backend = "127.0.0.1:${toString vlessXhttpPort}"; }
    ];

  relaySniEntries =
    lib.optionals (relayCfg.enable && serverCfg.vlessTcp.enable) [
      { sni = relayCfg.vlessTcp.sni; backend = "127.0.0.1:${toString relayTcpPort}"; }
    ]
    ++ lib.optionals (relayCfg.enable && serverCfg.vlessGrpc.enable) [
      { sni = relayCfg.vlessGrpc.sni; backend = "127.0.0.1:${toString relayGrpcPort}"; }
    ]
    ++ lib.optionals (relayCfg.enable && serverCfg.vlessXhttp.enable) [
      { sni = relayCfg.vlessXhttp.sni; backend = "127.0.0.1:${toString relayXhttpPort}"; }
    ];

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
    ../sni-router.nix
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

    # SNI routing (server/relay mode only)
    roles.sni-router = mkIf cfg.server.enable {
      enable = true;
      entries = serverSniEntries ++ relaySniEntries;
    };

    # Xray systemd service (server/relay mode only)
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
  };
}
```

Key changes from original:
- Removed `nginxSniEntries` from `emptyConfig`
- Removed `allNginxEntries` variable
- Removed `services.nginx` block
- Removed `networking.firewall.allowedTCPPorts`
- Added `../sni-router.nix` to imports
- Added `roles.sni-router` config block that builds entries from server/relay transport state
- Added port constants and SNI entry builders directly in the coordinator
- Added `serverCfg`/`relayCfg` let-bindings to access transport options

- [ ] **Step 4: Verify the build evaluates**

```bash
nix eval .#nixosConfigurations.veles.config.roles.sni-router.entries --json 2>&1 | head -20
nix eval .#nixosConfigurations.buyan.config.roles.sni-router.entries --json 2>&1 | head -20
```

Expected: JSON arrays with the SNI entries for each machine. Veles should have 6 entries (3 server + 3 relay), buyan should have 3 (server only).

- [ ] **Step 5: Commit**

```bash
git add roles/network/xray/default.nix roles/network/xray/server.nix roles/network/xray/relay.nix
git commit -m "refactor(xray): delegate nginx SNI routing to shared sni-router module"
```

---

### Task 3: Add nixpkgs-unstable Flake Input

**Files:**
- Modify: `flake.nix`

- [ ] **Step 1: Add nixpkgs-unstable input and pass to veles**

In `flake.nix`, add the unstable input to `inputs` (after line 5):

```nix
nixpkgs-unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable";
```

Update the `outputs` function signature (line 14) to destructure it:

```nix
{ nixpkgs, nixpkgs-unstable, ... }@inputs:
```

Add an overlay to the veles nixosConfiguration (lines 56–63). Replace the existing veles block with:

```nix
      # VPS 1 CPU, 1GB RAM (RU)
      nixosConfigurations."veles" = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = inputs;
        modules = [
          {
            nixpkgs.overlays = (import ./overlays) ++ [
              (final: prev: {
                telemt = nixpkgs-unstable.legacyPackages.${prev.system}.telemt;
              })
            ];
          }
          ./machines/veles
          ./users/o__ni
        ];
      };
```

- [ ] **Step 2: Verify telemt package resolves**

```bash
nix eval .#nixosConfigurations.veles.pkgs.telemt.name 2>&1
```

Expected: something like `"telemt-3.3.28"`

- [ ] **Step 3: Commit**

```bash
git add flake.nix
git commit -m "feat: add nixpkgs-unstable input for telemt package"
```

---

### Task 4: Create MTProxy Module

**Files:**
- Create: `roles/network/mtproxy.nix`

- [ ] **Step 1: Create `roles/network/mtproxy.nix`**

```nix
# roles/network/mtproxy.nix
#
# Telegram MTProxy via telemt (Rust implementation).
# Runs in fake-TLS (ee) mode behind sni-router.
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.roles.mtproxy;

  configFile = pkgs.writeText "telemt.toml" ''
    [general]
    use_middle_proxy = true
    log_level = "normal"

    [general.modes]
    classic = false
    secure = false
    tls = true

    [server]
    port = ${toString cfg.port}
    proxy_protocol = true

    [[server.listeners]]
    ip = "127.0.0.1"

    [censorship]
    tls_domain = "${cfg.tls.domain}"
    mask = true
    tls_emulation = true
    tls_front_dir = "/var/lib/telemt/tlsfront"

    [access.users]
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: secret: ''${name} = "${secret}"'') cfg.users
    )}
  '';
in
{
  options.roles.mtproxy = {
    enable = mkEnableOption "Telegram MTProxy via telemt";

    tls.domain = mkOption {
      type = types.str;
      description = "Domain for fake-TLS SNI (used for TLS emulation and sni-router entry)";
      example = "google.com";
    };

    port = mkOption {
      type = types.port;
      default = 9100;
      description = "Local port telemt listens on (behind sni-router)";
    };

    users = mkOption {
      type = types.attrsOf types.str;
      description = "Map of username to 32-char hex secret";
      example = {
        alice = "00000000000000000000000000000001";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.users != { };
        message = "roles.mtproxy.users must contain at least one user";
      }
    ];

    roles.sni-router.entries = [
      {
        sni = cfg.tls.domain;
        backend = "127.0.0.1:${toString cfg.port}";
      }
    ];

    systemd.services.telemt = {
      description = "Telegram MTProxy (telemt)";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.telemt}/bin/telemt ${configFile}";
        DynamicUser = true;
        StateDirectory = "telemt";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ "/var/lib/telemt" ];
      };
    };
  };
}
```

- [ ] **Step 2: Commit**

```bash
git add roles/network/mtproxy.nix
git commit -m "feat: add mtproxy module for Telegram proxy via telemt"
```

---

### Task 5: Configure Veles

**Files:**
- Modify: `machines/veles/default.nix`
- Modify: `secrets/secrets.json` (manual — add `mtproxy.users`)

- [ ] **Step 1: Add mtproxy secrets to `secrets/secrets.json`**

Add the following to `secrets/secrets.json` (the user must generate or supply the actual hex secret):

```json
{
  "mtproxy": {
    "users": {
      "main": "REPLACE_WITH_32_HEX_CHARS_SECRET"
    }
  }
}
```

Generate a secret with: `openssl rand -hex 16`

- [ ] **Step 2: Update `machines/veles/default.nix`**

Add the mtproxy import to the imports list (after line 15):

```nix
    ../../roles/network/mtproxy.nix
```

Add the mtproxy role config after the `roles.xray` block (after line 106), before `roles.stream-forwarder`:

```nix
  roles.mtproxy = {
    enable = true;
    tls.domain = "google.com";
    port = 9100;
    users = secrets.mtproxy.users;
  };
```

Also add secrets to the `let` bindings (after line 7):

```nix
  secrets = import ../../secrets;
```

And reference it — note that `secrets` is already partially used via `(import ../../secrets).ip.mokosh.address` on line 7. Refactor the let block to:

```nix
let
  hostname = "veles";
  secrets = import ../../secrets;
  mokoshIp = secrets.ip.mokosh.address;
in
```

- [ ] **Step 3: Verify the full build evaluates**

```bash
nix eval .#nixosConfigurations.veles.config.roles.sni-router.entries --json 2>&1 | head -20
nix eval .#nixosConfigurations.veles.config.systemd.services.telemt.serviceConfig.ExecStart 2>&1
nix eval .#nixosConfigurations.buyan.config.roles.sni-router.entries --json 2>&1 | head -20
```

Expected for veles sni-router entries: 7 entries (3 xray server + 3 xray relay + 1 mtproxy).
Expected for buyan: 3 entries (xray server only), unchanged behavior.

- [ ] **Step 4: Build veles to verify no errors**

```bash
nix build .#nixosConfigurations.veles.config.system.build.toplevel --dry-run 2>&1 | tail -20
```

Expected: successful evaluation (dry-run doesn't need to download/build, just evaluate).

- [ ] **Step 5: Commit**

```bash
git add machines/veles/default.nix secrets/secrets.json
git commit -m "feat(veles): enable mtproxy with telemt behind sni-router"
```

---

### Task 6: Final Verification

- [ ] **Step 1: Verify buyan still evaluates correctly**

```bash
nix build .#nixosConfigurations.buyan.config.system.build.toplevel --dry-run 2>&1 | tail -20
```

Expected: successful evaluation — buyan should work exactly as before, now using sni-router under the hood.

- [ ] **Step 2: Verify all machines evaluate**

```bash
nix build .#nixosConfigurations.veles.config.system.build.toplevel --dry-run 2>&1 | tail -5
nix build .#nixosConfigurations.buyan.config.system.build.toplevel --dry-run 2>&1 | tail -5
nix build .#nixosConfigurations.mokosh.config.system.build.toplevel --dry-run 2>&1 | tail -5
nix build .#nixosConfigurations.nixpi.config.system.build.toplevel --dry-run 2>&1 | tail -5
```

Expected: all evaluate successfully. mokosh and nixpi don't import xray/sni-router, so they should be unaffected.

- [ ] **Step 3: Inspect generated nginx config for veles**

```bash
nix eval .#nixosConfigurations.veles.config.services.nginx.streamConfig --raw 2>&1
```

Expected: a `map $ssl_preread_server_name $sni_backend` block with 7 entries (3 xray server SNIs + 3 xray relay SNIs + 1 mtproxy SNI), plus the `server { listen 443; ... }` block.

- [ ] **Step 4: Inspect generated telemt config**

```bash
nix eval .#nixosConfigurations.veles.config.systemd.services.telemt.serviceConfig.ExecStart --raw 2>&1
```

Expected: path to telemt binary followed by path to the generated config.toml in the nix store. Optionally read the config file to verify its contents.
