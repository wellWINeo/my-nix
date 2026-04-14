# Telemt-Xray Relay Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route telemt (MTProxy) traffic through xray relay's SOCKS5 inbound to reach buyan via VLESS, and universally filter `singBoxUsers` by hostname.

**Architecture:** A shared `filterProxyUsersForHost` function filters `singBoxUsers` by a new `hosts` property. The xray relay gains a localhost SOCKS5 inbound routed to its existing balancer. Telemt gets an optional `upstream` setting to route through that SOCKS5. Veles wires everything together.

**Tech Stack:** NixOS modules, Nix language, xray-core, telemt

---

## File Structure

| Action | File | Responsibility |
|--------|------|----------------|
| Create | `common/filter-proxy-users.nix` | `filterProxyUsersForHost` function |
| Modify | `secrets/secrets.dummy.json` | Add `hosts` field to `singBoxUsers` entries |
| Modify | `roles/network/xray/server.nix` | Use `filterProxyUsersForHost` |
| Modify | `roles/network/xray/relay.nix` | Use `filterProxyUsersForHost` + SOCKS5 inbound + options |
| Modify | `roles/network/xray/subscriptions.nix` | Use `filterProxyUsersForHost` |
| Modify | `roles/network/sing-box/server.nix` | Use `filterProxyUsersForHost` |
| Modify | `roles/network/mtproxy.nix` | Add `upstream` option, generate `[[upstreams]]` block |
| Modify | `machines/veles/default.nix` | Enable relay + socks + mtproxy upstream |

---

### Task 1: Create `filterProxyUsersForHost`

**Files:**
- Create: `common/filter-proxy-users.nix`

- [ ] **Step 1: Create the filtering function**

Create `common/filter-proxy-users.nix`:

```nix
# common/filter-proxy-users.nix
#
# Filters singBoxUsers by the `hosts` property for a given hostname.
#   hosts = "*"           → allowed everywhere (also the default when absent)
#   hosts = "veles"       → only on veles
#   hosts = ["veles", "buyan"] → only on veles and buyan
{ lib }:
hostname: users:
builtins.filter (
  u:
  let
    h = u.hosts or "*";
  in
  if h == "*" then
    true
  else if builtins.isList h then
    builtins.elem hostname h
  else
    h == hostname
) users
```

- [ ] **Step 2: Verify it evaluates correctly**

Run:
```bash
cd /Users/o__ni/Code/Git/my-nix
nix-instantiate --eval --strict -E '
  let
    lib = import <nixpkgs/lib>;
    filter = import ./common/filter-proxy-users.nix { inherit lib; };
    users = [
      { name = "alice"; hosts = "*"; }
      { name = "bob"; hosts = "veles"; }
      { name = "carol"; hosts = ["veles" "buyan"]; }
      { name = "dave"; hosts = "buyan"; }
    ];
  in map (u: u.name) (filter "veles" users)
'
```

Expected: `[ "alice" "bob" "carol" ]`

- [ ] **Step 3: Commit**

```bash
git add common/filter-proxy-users.nix
git commit -m "feat: add filterProxyUsersForHost helper"
```

---

### Task 2: Update secrets dummy schema

**Files:**
- Modify: `secrets/secrets.dummy.json`

- [ ] **Step 1: Add `hosts` field to dummy singBoxUsers entry**

In `secrets/secrets.dummy.json`, change the `singBoxUsers` entry from:

```json
"singBoxUsers": [
  {
    "uuid": "00000000-0000-0000-0000-000000000000",
    "name": "dummy",
    "password": "dummypassword"
  }
]
```

to:

```json
"singBoxUsers": [
  {
    "uuid": "00000000-0000-0000-0000-000000000000",
    "name": "dummy",
    "password": "dummypassword",
    "hosts": "*"
  }
]
```

- [ ] **Step 2: Commit**

```bash
git add secrets/secrets.dummy.json
git commit -m "chore(secrets): add hosts field to singBoxUsers dummy schema"
```

---

### Task 3: Wire `filterProxyUsersForHost` into xray server

**Files:**
- Modify: `roles/network/xray/server.nix:14-33`

- [ ] **Step 1: Replace direct `secrets.singBoxUsers` with filtered users**

In `roles/network/xray/server.nix`, replace the `let` block's user references. Change lines 14-33 from:

```nix
let
  cfg = config.roles.xray.server;
  secrets = import ../../../secrets;
  transports = import ./transports { inherit lib; };
  transportList = lib.attrValues transports;

  shortIds = secrets.xray.reality.shortIds or [ ];

  clients = {
    withFlow = map (u: {
      id = u.uuid;
      flow = "xtls-rprx-vision";
      email = "${u.name}@xray";
    }) secrets.singBoxUsers;

    noFlow = map (u: {
      id = u.uuid;
      email = "${u.name}@xray";
    }) secrets.singBoxUsers;
  };
```

to:

```nix
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
```

- [ ] **Step 2: Commit**

```bash
git add roles/network/xray/server.nix
git commit -m "feat(xray/server): filter singBoxUsers by hostname"
```

---

### Task 4: Wire `filterProxyUsersForHost` into xray relay

**Files:**
- Modify: `roles/network/xray/relay.nix:15-35`

- [ ] **Step 1: Replace direct `secrets.singBoxUsers` with filtered users**

In `roles/network/xray/relay.nix`, change lines 15-35 from:

```nix
let
  cfg = config.roles.xray.relay;
  serverCfg = config.roles.xray.server;
  secrets = import ../../../secrets;
  transports = import ./transports { inherit lib; };
  transportList = lib.attrValues transports;

  shortIds = secrets.xray.reality.shortIds or [ ];

  clients = {
    withFlow = map (u: {
      id = u.uuid;
      flow = "xtls-rprx-vision";
      email = "${u.name}@xray";
    }) secrets.singBoxUsers;

    noFlow = map (u: {
      id = u.uuid;
      email = "${u.name}@xray";
    }) secrets.singBoxUsers;
  };
```

to:

```nix
let
  cfg = config.roles.xray.relay;
  serverCfg = config.roles.xray.server;
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
```

- [ ] **Step 2: Commit**

```bash
git add roles/network/xray/relay.nix
git commit -m "feat(xray/relay): filter singBoxUsers by hostname"
```

---

### Task 5: Wire `filterProxyUsersForHost` into xray subscriptions

**Files:**
- Modify: `roles/network/xray/subscriptions.nix:19-24,100-107`

- [ ] **Step 1: Add filter import and filtered users variable**

In `roles/network/xray/subscriptions.nix`, change lines 19-24 from:

```nix
let
  cfg = config.roles.xray.subscriptions;
  serverCfg = config.roles.xray.server;
  secrets = import ../../../secrets;
  transports = import ./transports { inherit lib; };
  transportList = lib.attrValues transports;
```

to:

```nix
let
  cfg = config.roles.xray.subscriptions;
  serverCfg = config.roles.xray.server;
  secrets = import ../../../secrets;
  filterProxyUsersForHost = import ../../../common/filter-proxy-users.nix { inherit lib; };
  transports = import ./transports { inherit lib; };
  transportList = lib.attrValues transports;
  users = filterProxyUsersForHost config.networking.hostName secrets.singBoxUsers;
```

- [ ] **Step 2: Replace `secrets.singBoxUsers` with `users` in subscription generation**

In the same file, change line 106 from:

```nix
        '') secrets.singBoxUsers
```

to:

```nix
        '') users
```

- [ ] **Step 3: Commit**

```bash
git add roles/network/xray/subscriptions.nix
git commit -m "feat(xray/subscriptions): filter singBoxUsers by hostname"
```

---

### Task 6: Wire `filterProxyUsersForHost` into sing-box server

**Files:**
- Modify: `roles/network/sing-box/server.nix:10-12,32-35,48-51,65-68`

- [ ] **Step 1: Add filter import and filtered users variable**

In `roles/network/sing-box/server.nix`, change lines 10-12 from:

```nix
let
  cfg = config.roles.sing-box-server;
  secrets = import ../../../secrets;
```

to:

```nix
let
  cfg = config.roles.sing-box-server;
  secrets = import ../../../secrets;
  filterProxyUsersForHost = import ../../../common/filter-proxy-users.nix { inherit lib; };
  users = filterProxyUsersForHost config.networking.hostName secrets.singBoxUsers;
```

- [ ] **Step 2: Replace all `secrets.singBoxUsers` references with `users`**

In the same file, there are three occurrences of `secrets.singBoxUsers` (lines 32-35, 48-51, 65-68). Replace each one:

Line 32-35 (vless-ws users):
```nix
          users = map (u: {
            name = u.name;
            uuid = u.uuid;
          }) secrets.singBoxUsers;
```
becomes:
```nix
          users = map (u: {
            name = u.name;
            uuid = u.uuid;
          }) users;
```

Line 48-51 (vless-grpc users):
```nix
          users = map (u: {
            name = u.name;
            uuid = u.uuid;
          }) secrets.singBoxUsers;
```
becomes:
```nix
          users = map (u: {
            name = u.name;
            uuid = u.uuid;
          }) users;
```

Line 65-68 (naive users):
```nix
          users = map (u: {
            username = u.name;
            password = u.password;
          }) secrets.singBoxUsers;
```
becomes:
```nix
          users = map (u: {
            username = u.name;
            password = u.password;
          }) users;
```

- [ ] **Step 3: Commit**

```bash
git add roles/network/sing-box/server.nix
git commit -m "feat(sing-box/server): filter singBoxUsers by hostname"
```

---

### Task 7: Add SOCKS5 inbound to xray relay

**Files:**
- Modify: `roles/network/xray/relay.nix:40-85,88-127`

- [ ] **Step 1: Add SOCKS5 inbound to relayConfig**

In `roles/network/xray/relay.nix`, change the `relayConfig` block (lines 40-85). Add the SOCKS5 inbound and routing rule.

Change line 41 (inbounds) from:

```nix
    inbounds = map (
```

to:

```nix
    inbounds = lib.optionals cfg.socks.enable [
      {
        listen = "127.0.0.1";
        port = cfg.socks.port;
        protocol = "socks";
        tag = "socks-relay-in";
        settings = {
          auth = "noauth";
          udp = true;
        };
      }
    ] ++ map (
```

Change the routing rules (lines 61-68) from:

```nix
      rules = lib.optionals (enabledInbound != [ ]) [
        {
          type = "field";
          inboundTag = map (
            t: if t.name == "vlessGrpc" then "vless-grpcFwd-in" else "${t.tagPrefix}-fwd-in"
          ) enabledInbound;
          balancerTag = "relay-balancer";
        }
      ];
```

to:

```nix
      rules = lib.optionals cfg.socks.enable [
        {
          type = "field";
          inboundTag = [ "socks-relay-in" ];
          balancerTag = "relay-balancer";
        }
      ] ++ lib.optionals (enabledInbound != [ ]) [
        {
          type = "field";
          inboundTag = map (
            t: if t.name == "vlessGrpc" then "vless-grpcFwd-in" else "${t.tagPrefix}-fwd-in"
          ) enabledInbound;
          balancerTag = "relay-balancer";
        }
      ];
```

- [ ] **Step 2: Add SOCKS5 options**

In the same file, add the `socks` option block. Change lines 88-89 from:

```nix
  options.roles.xray.relay = {
    enable = mkEnableOption "relay traffic to another xray server";
```

to:

```nix
  options.roles.xray.relay = {
    enable = mkEnableOption "relay traffic to another xray server";

    socks = {
      enable = mkEnableOption "local SOCKS5 inbound for relay";
      port = mkOption {
        type = types.port;
        default = 1080;
        description = "SOCKS5 listen port on 127.0.0.1";
      };
    };
```

- [ ] **Step 3: Commit**

```bash
git add roles/network/xray/relay.nix
git commit -m "feat(xray/relay): add localhost SOCKS5 inbound option"
```

---

### Task 8: Add upstream option to mtproxy module

**Files:**
- Modify: `roles/network/mtproxy.nix:17-44,47-69`

- [ ] **Step 1: Add upstream to generated telemt.toml**

In `roles/network/mtproxy.nix`, change the `configFile` definition (lines 17-44) from:

```nix
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
```

to:

```nix
  configFile = pkgs.writeText "telemt.toml" (''
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
  '' + lib.optionalString (cfg.upstream != null) ''

    [[upstreams]]
    type = "socks5"
    address = "${cfg.upstream}"
  '');
```

- [ ] **Step 2: Add upstream option**

In the same file, add the `upstream` option after the `users` option. Change lines 62-69 from:

```nix
    users = mkOption {
      type = types.attrsOf types.str;
      description = "Map of username to 32-char hex secret";
      example = {
        alice = "00000000000000000000000000000001";
      };
    };
  };
```

to:

```nix
    users = mkOption {
      type = types.attrsOf types.str;
      description = "Map of username to 32-char hex secret";
      example = {
        alice = "00000000000000000000000000000001";
      };
    };

    upstream = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "SOCKS5 upstream address (host:port). Null = direct via middle proxies.";
      example = "127.0.0.1:1080";
    };
  };
```

- [ ] **Step 3: Commit**

```bash
git add roles/network/mtproxy.nix
git commit -m "feat(mtproxy): add optional SOCKS5 upstream for telemt"
```

---

### Task 9: Wire veles machine config

**Files:**
- Modify: `machines/veles/default.nix:66-91`

- [ ] **Step 1: Enable relay with SOCKS5 and configure mtproxy upstream**

In `machines/veles/default.nix`, change lines 66-91 from:

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

  roles.mtproxy = {
    enable = true;
    tls.domain = "api.ok.ru";
    port = 9100;
    users = secrets.mtproxy.users;
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
    relay = {
      enable = true;
      socks.enable = true;
      user = builtins.head secrets.singBoxUsers;
      target = {
        server = secrets.ip.buyan.address;
        reality = {
          publicKey = secrets.xray.buyan.reality.publicKey;
          shortId = builtins.head (secrets.xray.reality.shortIds);
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
    };
  };

  roles.mtproxy = {
    enable = true;
    tls.domain = "api.ok.ru";
    port = 9100;
    upstream = "127.0.0.1:1080";
    users = secrets.mtproxy.users;
  };
```

> **Note to implementor:** The `secrets.xray.buyan.reality.publicKey` path assumes this key exists in `secrets.json`. The actual path may differ — check the real secrets structure and adjust. The relay `user` should also be a user whose `hosts` includes `"veles"` (or `"*"`). The relay target `serverName` values must match buyan's xray server SNIs exactly (confirmed from `machines/buyan/default.nix`).

- [ ] **Step 2: Verify the config evaluates**

Run:
```bash
cd /Users/o__ni/Code/Git/my-nix
nix eval .#nixosConfigurations.veles.config.roles.xray.relay.enable 2>&1 | head -20
```

Expected: `true` (or a meaningful error about missing secrets, not a Nix syntax/type error)

- [ ] **Step 3: Commit**

```bash
git add machines/veles/default.nix
git commit -m "feat(veles): enable xray relay to buyan + mtproxy SOCKS5 upstream"
```

---

### Task 10: Update secrets.json with hosts + buyan reality key

**Files:**
- Modify: `secrets/secrets.json` (encrypted — must be decrypted, edited, re-encrypted)

> **Note to implementor:** This task requires GPG access to decrypt `secrets.json.gpg`. The changes needed are:
> 1. Add `"hosts": "*"` (or appropriate value) to each entry in `singBoxUsers`
> 2. Add buyan's Reality public key at a path like `xray.buyan.reality.publicKey` (or wherever the veles config references it)
> 3. Re-encrypt and commit

This task may need to be done manually by the repo owner.

- [ ] **Step 1: Decrypt, add `hosts` to all singBoxUsers entries, add buyan reality pubkey**
- [ ] **Step 2: Re-encrypt and commit**

```bash
git add secrets/secrets.json.gpg
git commit -m "chore(secrets): add hosts to singBoxUsers + buyan reality pubkey"
```
