# Telemt-Xray Relay Pipeline Design

## Goal

Route Telegram MTProxy (telemt) traffic through xray relay to achieve:

```
client -- mtproxy --> veles[telemt] -- socks5 --> veles[xray relay] -- vless --> buyan
```

## Changes

### 1. Universal user filtering: `filterProxyUsersForHost`

**File:** `common/filter-proxy-users.nix` (new)

A pure function that filters `singBoxUsers` entries by the `hosts` property matched against a machine's hostname.

```nix
{ lib }:
hostname: users:
  builtins.filter (u:
    let h = u.hosts or "*"; in
    if h == "*" then true
    else if builtins.isList h then builtins.elem hostname h
    else h == hostname
  ) users
```

**`hosts` semantics:**
- `"*"` (or absent) — user provisioned on all machines
- `"veles"` — only on veles
- `["veles", "buyan"]` — only on veles and buyan

**Consumers to update** (switch from `secrets.singBoxUsers` to `filterProxyUsersForHost config.networking.hostName secrets.singBoxUsers`):
- `roles/network/xray/server.nix`
- `roles/network/xray/relay.nix`
- `roles/network/xray/subscriptions.nix`
- `roles/network/sing-box/server.nix`

**Scope:** Only `singBoxUsers`. MTProxy users (`secrets.mtproxy.users`) are not filtered.

### 2. Relay SOCKS5 inbound

**File:** `roles/network/xray/relay.nix` (modify)

Add options:

```nix
roles.xray.relay.socks = {
  enable = mkEnableOption "local SOCKS5 inbound for relay";
  port = mkOption { type = types.port; default = 1080; };
};
```

When enabled, add to relay's xray config:

**Inbound:**
```json
{
  "listen": "127.0.0.1",
  "port": 1080,
  "protocol": "socks",
  "tag": "socks-relay-in",
  "settings": { "auth": "noauth", "udp": true }
}
```

**Routing rule:**
```json
{
  "type": "field",
  "inboundTag": ["socks-relay-in"],
  "balancerTag": "relay-balancer"
}
```

The SOCKS5 inbound shares the existing `relay-balancer` (leastPing across all enabled outbound transports to the target server).

### 3. Telemt upstream option

**File:** `roles/network/mtproxy.nix` (modify)

Add option:

```nix
roles.mtproxy.upstream = mkOption {
  type = types.nullOr types.str;
  default = null;
  description = "SOCKS5 upstream address (e.g. 127.0.0.1:1080). Null = direct connection.";
};
```

When `upstream != null`, append to generated `telemt.toml`:

```toml
[[upstreams]]
type = "socks5"
address = "127.0.0.1:1080"
```

When `upstream == null`, no `[[upstreams]]` section (current behavior).

### 4. Secrets schema update

**File:** `secrets/secrets.json` (modify)

Add `hosts` property to each `singBoxUsers` entry:

```json
{
  "uuid": "...",
  "name": "alice",
  "password": "...",
  "hosts": "*"
}
```

Type: `string | string[]`

### 5. Veles machine wiring

**File:** `machines/veles/default.nix` (modify)

Enable relay targeting buyan with SOCKS5, and configure telemt upstream:

```nix
roles.xray = {
  enable = true;
  server = {
    enable = true;
    reality.privateKeyFile = "/etc/nixos/secrets/xray-reality-private-key";
    vlessTcp  = { enable = true; sni = "api.oneme.ru"; };
    vlessGrpc = { enable = true; sni = "avatars.mds.yandex.net"; };
    vlessXhttp = { enable = true; sni = "onlymir.ru"; };
  };
  relay = {
    enable = true;
    socks.enable = true;
    user = /* first filtered user or specific user */;
    target = {
      server = secrets.ip.buyan.address;
      reality = { /* buyan's Reality public key, shortId, etc. */ };
      vlessTcp.enable = true;
      vlessGrpc.enable = true;
      vlessXhttp.enable = true;
    };
  };
};

roles.mtproxy = {
  enable = true;
  tls.domain = "api.ok.ru";
  upstream = "127.0.0.1:1080";
  users = secrets.mtproxy.users;
};
```

## Out of scope

- Filtering `secrets.mtproxy.users` by host (separate user structure)
- Per-user upstream routing in telemt (all users share the same upstream)
- Auth on the SOCKS5 inbound (localhost-only is sufficient)
