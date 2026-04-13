# MTProxy (telemt) + SNI Router — Design Spec

## Overview

Add Telegram MTProxy support to veles using [telemt](https://github.com/telemt/telemt) (Rust MTProxy implementation) in fake-TLS (ee) mode. To share port 443 with xray via SNI-based routing, extract nginx stream config into a reusable `sni-router` module.

## Components

### 1. SNI Router (`roles/network/sni-router.nix`)

A shared NixOS module that owns the nginx stream `server` block on port 443. Other modules register routing entries via a list option.

**Options:**

```nix
roles.sni-router = {
  enable = mkEnableOption "SNI-based TLS routing via nginx stream";

  port = mkOption {
    type = types.port;
    default = 443;
    description = "External port to listen on";
  };

  entries = mkOption {
    type = types.listOf (types.submodule {
      options = {
        sni = mkOption { type = types.str; };
        backend = mkOption { type = types.str; };
        proxyProtocol = mkOption { type = types.bool; default = true; };
      };
    });
    default = [];
    description = "List of SNI → backend mappings";
  };

  defaultBackend = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = "Fallback backend; defaults to first entry if null";
  };
};
```

**Generated nginx streamConfig:**

```nginx
map $ssl_preread_server_name $sni_backend {
    <sni1>  <backend1>;
    <sni2>  <backend2>;
    default <defaultBackend or first entry>;
}

server {
    listen <port>;
    ssl_preread on;
    proxy_pass $sni_backend;
    proxy_protocol on;
}
```

**Firewall:** Opens `cfg.port` in `networking.firewall.allowedTCPPorts`.

**Assertion:** At least one entry must exist when enabled.

All backends receive PROXY protocol headers (both xray and telemt support `proxy_protocol = true`).

### 2. MTProxy Role (`roles/network/mtproxy.nix`)

A standalone NixOS module for running telemt.

**Options:**

```nix
roles.mtproxy = {
  enable = mkEnableOption "Telegram MTProxy via telemt";

  tls.domain = mkOption {
    type = types.str;
    description = "Domain for fake-TLS SNI (used for both TLS emulation and sni-router entry)";
  };

  port = mkOption {
    type = types.port;
    default = 9100;
    description = "Local port telemt listens on (behind sni-router)";
  };

  users = mkOption {
    type = types.attrsOf types.str;
    description = "Map of username → 32-char hex secret";
  };
};
```

**Generated config.toml:**

```toml
[general]
use_middle_proxy = true
log_level = "normal"

[general.modes]
classic = false
secure = false
tls = true

[server]
port = <cfg.port>
proxy_protocol = true

[[server.listeners]]
ip = "127.0.0.1"

[censorship]
tls_domain = "<cfg.tls.domain>"
mask = true
tls_emulation = true

[access.users]
<name1> = "<hex1>"
<name2> = "<hex2>"
```

**Systemd service:**

- `ExecStart = "${pkgs.telemt}/bin/telemt ${configFile}"`
- Hardened: `DynamicUser = true`, `NoNewPrivileges = true`, `PrivateTmp = true`
- `StateDirectory = "telemt"` for TLS emulation cache (`tls_front_dir` set to state dir)
- After `network.target`

**SNI router integration:** Adds entry to `roles.sni-router.entries`:

```nix
{ sni = cfg.tls.domain; backend = "127.0.0.1:${toString cfg.port}"; proxyProtocol = true; }
```

### 3. Xray Refactor

Remove nginx and firewall ownership from `roles/network/xray/default.nix`. Instead, populate `roles.sni-router.entries`.

**Changes to `default.nix`:**

- Remove the `services.nginx` block entirely
- Remove `networking.firewall.allowedTCPPorts`
- Add: collect SNI entries from server/relay configs and write them to `roles.sni-router.entries`
- Remove `nginxSniEntries` from `emptyConfig`

**Changes to `server.nix`:**

- Keep `nginxSniEntries` in the config fragment (it's just data) — the coordinator reads it and maps to `roles.sni-router.entries` format: `{ sni; backend = "127.0.0.1:<port>"; proxyProtocol = true; }`

Alternatively, remove `nginxSniEntries` from server/relay entirely and have the coordinator build them directly from the enabled transports and their ports. This is cleaner — the coordinator already knows which transports are enabled and their ports.

**Decision:** Remove `nginxSniEntries` from server.nix/relay.nix. The coordinator builds sni-router entries directly.

### 4. Unstable Nixpkgs Input

telemt is available in nixpkgs-unstable (v3.3.28) but not in nixos-25.11.

**Changes to `flake.nix`:**

- Add input: `nixpkgs-unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable";`
- Pass `nixpkgs-unstable` to veles via `specialArgs`

**Overlay for telemt** (inline in veles's nixosSystem definition, not in shared overlays — only veles needs it):

```nix
{ nixpkgs.overlays = [ (final: prev: { telemt = inputs.nixpkgs-unstable.legacyPackages.${prev.system}.telemt; }) ]; }
```

### 5. Veles Machine Config

```nix
# machines/veles/default.nix
imports = [
  ../../roles/network/sni-router.nix
  ../../roles/network/mtproxy.nix
  ../../roles/network/xray
  # ... existing imports
];

roles.sni-router.enable = true;

roles.mtproxy = {
  enable = true;
  tls.domain = "<chosen-domain>";
  port = 9100;
  users = secrets.mtproxy.users;
};
```

The xray config block stays unchanged — the xray coordinator now feeds sni-router instead of owning nginx directly.

### 6. Secrets

Add `mtproxy.users` to `secrets/secrets.json`:

```json
{
  "mtproxy": {
    "users": {
      "user1": "00000000000000000000000000000001"
    }
  }
}
```

## File Changes Summary

| File | Action |
|------|--------|
| `roles/network/sni-router.nix` | **New** — shared SNI routing module |
| `roles/network/mtproxy.nix` | **New** — telemt MTProxy module |
| `roles/network/xray/default.nix` | **Modify** — remove nginx/firewall, add sni-router entries |
| `roles/network/xray/server.nix` | **Modify** — remove `nginxSniEntries` from config fragment |
| `roles/network/xray/relay.nix` | **Modify** — remove `nginxSniEntries` from config fragment |
| `flake.nix` | **Modify** — add nixpkgs-unstable input, pass to veles |
| `flake.nix` (veles module list) | **Modify** — add telemt overlay inline |
| `machines/veles/default.nix` | **Modify** — import sni-router + mtproxy, configure |
| `secrets/secrets.json` | **Modify** — add mtproxy.users |
