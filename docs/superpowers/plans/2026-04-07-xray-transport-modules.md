# Xray Transport Modules + Subscriptions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor `roles/network/xray/` so each transport protocol is a self-contained module, eliminate inbound/outbound duplication between server/client/relay, and add a per-user subscription endpoint (`https://<config-host>/xray-config/<uuid>`) served by a new sibling submodule that can run co-located with the server or on a different host.

**Architecture:** Per-transport modules in `roles/network/xray/transports/` each export option schema, inbound/outbound builders, and a `mkSubscriptionEntry` function. `server.nix`/`client.nix`/`relay.nix` become thin folds over the transport registry. A new `subscriptions.nix` owns a build-time derivation generating per-user base64 vless-URI files, served via an nginx HTTPS virtualhost that reuses the existing stream SNI routing when co-located.

**Tech Stack:** Nix / NixOS modules, nginx (stream + http), xray-core, bash (base64 in a `runCommand` derivation).

**Spec:** `docs/superpowers/specs/2026-04-07-xray-transport-modules-design.md`

**Testing approach:** This is a Nix refactor with no unit-test framework. "Tests" are:
1. `nix eval --json` to extract the generated xray config and diff it byte-by-byte (after `jq -S`) between baseline and refactored versions. Byte equivalence is required for Tasks 1–10.
2. `nix build .#nixosConfigurations.<host>.config.system.build.toplevel` for each affected host — must build successfully.
3. `nix flake check` at the end of each task.

---

## File Structure

**Created:**
- `roles/network/xray/transports/default.nix` — registry (imports each transport module, returns attrset).
- `roles/network/xray/transports/lib.nix` — shared helpers (reality settings builders, vnext wrapper, vless URI builder, base64 helper).
- `roles/network/xray/transports/tcp.nix` — VLESS+TCP+Vision.
- `roles/network/xray/transports/grpc.nix` — VLESS+gRPC.
- `roles/network/xray/transports/xhttp.nix` — VLESS+xHTTP.
- `roles/network/xray/subscriptions.nix` — subscription submodule (options, derivation, nginx vhost).

**Modified:**
- `roles/network/xray/default.nix` — import `subscriptions.nix`; add stream-map entry for subscription SNI when co-located.
- `roles/network/xray/server.nix` — fold over transport registry; add `publicAddress` and `reality.publicKey` options.
- `roles/network/xray/client.nix` — fold over transport registry.
- `roles/network/xray/relay.nix` — fold over transport registry.

**Deleted:**
- `roles/network/xray/options.nix` — option schema moves into transport modules.

---

## Task 0: Capture baseline xray config JSON for verification

**Files:**
- Create: `/tmp/xray-baseline/veles.json`
- Create: `/tmp/xray-baseline/buyan.json`

- [ ] **Step 1: Verify starting from clean main**

Run:
```bash
cd /Users/o__ni/Code/Git/my-nix
git status
git rev-parse HEAD
```
Expected: clean tree on `main`, commit matches latest.

- [ ] **Step 2: Extract the xray config template path for each host**

Run:
```bash
mkdir -p /tmp/xray-baseline
nix eval --raw .#nixosConfigurations.veles.config.systemd.services.xray.script > /tmp/xray-baseline/veles.script
nix eval --raw .#nixosConfigurations.buyan.config.systemd.services.xray.script > /tmp/xray-baseline/buyan.script
```
Expected: two non-empty files. Both contain a `cat /nix/store/...-xray-config-template.json` line.

- [ ] **Step 3: Resolve the template JSON and normalize it**

Run:
```bash
for host in veles buyan; do
  tpl=$(grep -oE '/nix/store/[^ ]+-xray-config-template\.json' /tmp/xray-baseline/$host.script | head -1)
  nix-store --realise "$tpl" >/dev/null
  jq -S . "$tpl" > /tmp/xray-baseline/$host.json
done
wc -l /tmp/xray-baseline/*.json
```
Expected: two normalized JSON files, each with >30 lines.

- [ ] **Step 4: Sanity-check both baselines contain all three transports**

Run:
```bash
for host in veles buyan; do
  echo "== $host =="
  jq '[.inbounds[].tag] | sort' /tmp/xray-baseline/$host.json
done
```
Expected: `["vless-grpc-in","vless-tcp-in","vless-xhttp-in"]` for each host.

- [ ] **Step 5: Commit a note (no code changes yet)**

No commit — baseline files live under `/tmp`. Keep the shell open or re-run Step 3 later.

---

## Task 1: Create `transports/lib.nix` with shared helpers

**Files:**
- Create: `roles/network/xray/transports/lib.nix`

- [ ] **Step 1: Write `transports/lib.nix`**

Create the file with:

```nix
# roles/network/xray/transports/lib.nix
#
# Shared helpers used by transport modules to build xray config fragments
# and vless:// subscription URIs. Keeping these here lets individual transport
# files stay focused on what is actually unique to each protocol.
{ lib }:

with lib;

rec {
  # Reality server-side realitySettings block. privateKey is injected at
  # runtime by the coordinator (see default.nix), so we leave it out here.
  mkRealityServerSettings =
    { sni, shortIds }:
    {
      target = "${sni}:443";
      serverNames = [ sni ];
      shortIds = shortIds;
    };

  # Reality client-side realitySettings block, used when connecting TO an
  # xray server (client or relay outbound). `reality` is an attrset with
  # publicKey/shortId/fingerprint and a fallback serverName.
  mkRealityClientSettings =
    { reality, serverName }:
    let
      sni = if serverName != "" then serverName else reality.serverName;
    in
    {
      publicKey = reality.publicKey;
      shortId = reality.shortId;
      serverName = sni;
      fingerprint = reality.fingerprint;
    };

  # Build a VLESS vnext outbound. `extraUser` is merged into the user entry
  # (used to add flow=xtls-rprx-vision for TCP+Vision).
  mkVnextOutbound =
    {
      tag,
      address,
      port,
      uuid,
      extraUser ? { },
      streamSettings,
    }:
    {
      protocol = "vless";
      tag = tag;
      settings = {
        vnext = [
          {
            address = address;
            port = port;
            users = [
              ({
                id = uuid;
                encryption = "none";
              } // extraUser)
            ];
          }
        ];
      };
      streamSettings = streamSettings;
    };

  # URL-encode a single string. Good enough for the characters that show up
  # in SNI, paths, gRPC service names, and fingerprints.
  urlEncode =
    str:
    let
      replace = pairs: s: foldl' (acc: p: builtins.replaceStrings [ (elemAt p 0) ] [ (elemAt p 1) ] acc) s pairs;
    in
    replace [
      [ "%" "%25" ]
      [ " " "%20" ]
      [ "/" "%2F" ]
      [ "?" "%3F" ]
      [ "#" "%23" ]
      [ "&" "%26" ]
      [ "=" "%3D" ]
    ] str;

  # Build a `vless://uuid@addr:port?k=v&...#tag` URI string from a params
  # attrset. Params are sorted for determinism.
  mkVlessUri =
    {
      uuid,
      addr,
      port ? 443,
      params,
      tag,
    }:
    let
      keys = lib.sort lessThan (lib.attrNames params);
      pairs = map (k: "${k}=${urlEncode (toString params.${k})}") keys;
      query = lib.concatStringsSep "&" pairs;
    in
    "vless://${uuid}@${addr}:${toString port}?${query}#${urlEncode tag}";
}
```

- [ ] **Step 2: Smoke-test it evaluates**

Run:
```bash
nix eval --impure --expr '
  let
    lib = (import <nixpkgs> {}).lib;
    h = import ./roles/network/xray/transports/lib.nix { inherit lib; };
  in h.mkVlessUri {
    uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
    addr = "vpn.example.com";
    params = { sni = "api.oneme.ru"; type = "tcp"; };
    tag = "vless-tcp";
  }
'
```
Expected: string containing `vless://aaaaaaaa-...@vpn.example.com:443?sni=api.oneme.ru&type=tcp#vless-tcp`.

- [ ] **Step 3: Commit**

```bash
git add roles/network/xray/transports/lib.nix
git commit -m "feat(xray): add transports/lib.nix with shared reality/vless helpers"
```

---

## Task 2: Create `transports/tcp.nix`

**Files:**
- Create: `roles/network/xray/transports/tcp.nix`

- [ ] **Step 1: Write `transports/tcp.nix`**

```nix
# roles/network/xray/transports/tcp.nix
#
# VLESS over direct TCP with Vision flow.
{ lib, helpers }:

with lib;

{
  name = "vlessTcp";
  tagPrefix = "vless-tcp";
  serverPort = 9000;
  relayPort = 9010;

  # --- Option schema fragments ---

  serverOptions = {
    enable = mkEnableOption "VLESS over direct TCP with Vision flow";
    sni = mkOption {
      type = types.str;
      default = "api.oneme.ru";
      description = "Reality SNI and camouflage target for TCP+Vision transport";
    };
  };

  clientOptions = {
    enable = mkEnableOption "VLESS over direct TCP with Vision flow";
    server = mkOption { type = types.str; description = "Server domain or IP"; };
    port = mkOption { type = types.port; default = 443; description = "Server port"; };
    serverName = mkOption {
      type = types.str;
      default = "";
      description = "Reality SNI for this transport (overrides shared reality.serverName)";
    };
    auth = {
      name = mkOption { type = types.str; default = ""; description = "Username (informational)"; };
      uuid = mkOption { type = types.str; description = "UUID for authentication"; };
    };
  };

  relayInboundOptions = {
    sni = mkOption {
      type = types.str;
      description = "SNI for relay TCP inbound (must differ from server's TCP SNI)";
    };
  };

  relayTargetOptions = {
    enable = mkEnableOption "relay outbound VLESS over direct TCP with Vision flow";
    serverName = mkOption {
      type = types.str;
      default = "";
      description = "Reality SNI for relay outbound TCP (overrides target.reality.serverName)";
    };
  };

  subscriptionUpstreamOptions = {
    enable = mkEnableOption "advertise VLESS+TCP+Vision in generated subscriptions";
    sni = mkOption {
      type = types.str;
      description = "Reality SNI clients will use for TCP+Vision connections";
    };
  };

  # --- Builders ---

  mkServerInbound =
    { cfg, clients, shortIds }:
    {
      listen = "127.0.0.1";
      port = 9000;
      protocol = "vless";
      tag = "vless-tcp-in";
      settings = {
        clients = clients.withFlow;
        decryption = "none";
      };
      streamSettings = {
        network = "tcp";
        security = "reality";
        realitySettings = helpers.mkRealityServerSettings { inherit (cfg) sni; inherit shortIds; };
        sockopt.acceptProxyProtocol = true;
      };
    };

  mkRelayInbound =
    { cfg, serverCfg, clients, shortIds }:
    {
      listen = "127.0.0.1";
      port = 9010;
      protocol = "vless";
      tag = "vless-tcp-fwd-in";
      settings = {
        clients = clients.withFlow;
        decryption = "none";
      };
      streamSettings = {
        network = "tcp";
        security = "reality";
        realitySettings = helpers.mkRealityServerSettings { inherit (cfg) sni; inherit shortIds; };
        sockopt.acceptProxyProtocol = true;
      };
    };

  mkClientOutbound =
    { cfg, realityCfg }:
    helpers.mkVnextOutbound {
      tag = "vless-tcp-out";
      address = cfg.server;
      port = cfg.port;
      uuid = cfg.auth.uuid;
      extraUser = { flow = "xtls-rprx-vision"; };
      streamSettings = {
        network = "tcp";
        security = "reality";
        realitySettings = helpers.mkRealityClientSettings {
          reality = realityCfg;
          serverName = cfg.serverName;
        };
      };
    };

  mkRelayOutbound =
    { cfg, targetCfg, realityCfg, user, serverAddr }:
    helpers.mkVnextOutbound {
      tag = "relay-tcp-out";
      address = serverAddr;
      port = 443;
      uuid = user.uuid;
      extraUser = { flow = "xtls-rprx-vision"; };
      streamSettings = {
        network = "tcp";
        security = "reality";
        realitySettings = helpers.mkRealityClientSettings {
          reality = realityCfg;
          serverName = cfg.serverName;
        };
      };
    };

  mkSubscriptionEntry =
    {
      serverAddr,
      uuid,
      fingerprint,
      realityPublicKey,
      shortId,
      cfg,
    }:
    helpers.mkVlessUri {
      inherit uuid;
      addr = serverAddr;
      port = 443;
      params = {
        encryption = "none";
        security = "reality";
        type = "tcp";
        flow = "xtls-rprx-vision";
        sni = cfg.sni;
        pbk = realityPublicKey;
        sid = shortId;
        fp = fingerprint;
      };
      tag = "vless-tcp";
    };
}
```

- [ ] **Step 2: Syntax check**

Run:
```bash
nix-instantiate --parse roles/network/xray/transports/tcp.nix >/dev/null && echo OK
```
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add roles/network/xray/transports/tcp.nix
git commit -m "feat(xray): add tcp transport module"
```

---

## Task 3: Create `transports/grpc.nix`

**Files:**
- Create: `roles/network/xray/transports/grpc.nix`

- [ ] **Step 1: Write `transports/grpc.nix`**

```nix
# roles/network/xray/transports/grpc.nix
#
# VLESS over gRPC.
{ lib, helpers }:

with lib;

{
  name = "vlessGrpc";
  tagPrefix = "vless-grpc";
  serverPort = 9001;
  relayPort = 9011;

  serverOptions = {
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

  clientOptions = {
    enable = mkEnableOption "VLESS over gRPC";
    server = mkOption { type = types.str; description = "Server domain or IP"; };
    port = mkOption { type = types.port; default = 443; description = "Server port"; };
    serverName = mkOption {
      type = types.str;
      default = "";
      description = "Reality SNI for this transport";
    };
    serviceName = mkOption {
      type = types.str;
      default = "VlGrpc";
      description = "gRPC service name (must match server)";
    };
    auth = {
      name = mkOption { type = types.str; default = ""; description = "Username (informational)"; };
      uuid = mkOption { type = types.str; description = "UUID for authentication"; };
    };
  };

  relayInboundOptions = {
    sni = mkOption {
      type = types.str;
      description = "SNI for relay gRPC inbound (must differ from server's gRPC SNI)";
    };
  };

  relayTargetOptions = {
    enable = mkEnableOption "relay outbound VLESS over gRPC";
    serverName = mkOption {
      type = types.str;
      default = "";
      description = "Reality SNI for relay outbound gRPC";
    };
    serviceName = mkOption {
      type = types.str;
      default = "VlGrpc";
      description = "gRPC service name of the target server";
    };
  };

  subscriptionUpstreamOptions = {
    enable = mkEnableOption "advertise VLESS+gRPC in generated subscriptions";
    sni = mkOption { type = types.str; description = "Reality SNI for gRPC"; };
    serviceName = mkOption {
      type = types.str;
      default = "VlGrpc";
      description = "gRPC service name clients must use";
    };
  };

  mkServerInbound =
    { cfg, clients, shortIds }:
    {
      listen = "127.0.0.1";
      port = 9001;
      protocol = "vless";
      tag = "vless-grpc-in";
      settings = {
        clients = clients.noFlow;
        decryption = "none";
      };
      streamSettings = {
        network = "grpc";
        security = "reality";
        realitySettings = (helpers.mkRealityServerSettings { inherit (cfg) sni; inherit shortIds; }) // {
          alpn = [ "h2" ];
        };
        grpcSettings = { serviceName = cfg.serviceName; };
        sockopt.acceptProxyProtocol = true;
      };
    };

  mkRelayInbound =
    { cfg, serverCfg, clients, shortIds }:
    {
      listen = "127.0.0.1";
      port = 9011;
      protocol = "vless";
      tag = "vless-grpcFwd-in";
      settings = {
        clients = clients.noFlow;
        decryption = "none";
      };
      streamSettings = {
        network = "grpc";
        security = "reality";
        realitySettings = (helpers.mkRealityServerSettings { inherit (cfg) sni; inherit shortIds; }) // {
          alpn = [ "h2" ];
        };
        grpcSettings = { serviceName = serverCfg.serviceName; };
        sockopt.acceptProxyProtocol = true;
      };
    };

  mkClientOutbound =
    { cfg, realityCfg }:
    helpers.mkVnextOutbound {
      tag = "vless-grpc-out";
      address = cfg.server;
      port = cfg.port;
      uuid = cfg.auth.uuid;
      streamSettings = {
        network = "grpc";
        security = "reality";
        realitySettings = helpers.mkRealityClientSettings {
          reality = realityCfg;
          serverName = cfg.serverName;
        };
        grpcSettings = { serviceName = cfg.serviceName; };
      };
    };

  mkRelayOutbound =
    { cfg, targetCfg, realityCfg, user, serverAddr }:
    helpers.mkVnextOutbound {
      tag = "relay-grpc-out";
      address = serverAddr;
      port = 443;
      uuid = user.uuid;
      streamSettings = {
        network = "grpc";
        security = "reality";
        realitySettings = helpers.mkRealityClientSettings {
          reality = realityCfg;
          serverName = cfg.serverName;
        };
        grpcSettings = { serviceName = cfg.serviceName; };
      };
    };

  mkSubscriptionEntry =
    {
      serverAddr,
      uuid,
      fingerprint,
      realityPublicKey,
      shortId,
      cfg,
    }:
    helpers.mkVlessUri {
      inherit uuid;
      addr = serverAddr;
      port = 443;
      params = {
        encryption = "none";
        security = "reality";
        type = "grpc";
        serviceName = cfg.serviceName;
        sni = cfg.sni;
        pbk = realityPublicKey;
        sid = shortId;
        fp = fingerprint;
        alpn = "h2";
      };
      tag = "vless-grpc";
    };
}
```

- [ ] **Step 2: Syntax check**

Run:
```bash
nix-instantiate --parse roles/network/xray/transports/grpc.nix >/dev/null && echo OK
```
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add roles/network/xray/transports/grpc.nix
git commit -m "feat(xray): add grpc transport module"
```

---

## Task 4: Create `transports/xhttp.nix`

**Files:**
- Create: `roles/network/xray/transports/xhttp.nix`

- [ ] **Step 1: Write `transports/xhttp.nix`**

```nix
# roles/network/xray/transports/xhttp.nix
#
# VLESS over xHTTP.
{ lib, helpers }:

with lib;

{
  name = "vlessXhttp";
  tagPrefix = "vless-xhttp";
  serverPort = 9002;
  relayPort = 9012;

  serverOptions = {
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

  clientOptions = {
    enable = mkEnableOption "VLESS over xHTTP";
    server = mkOption { type = types.str; description = "Server domain or IP"; };
    port = mkOption { type = types.port; default = 443; description = "Server port"; };
    serverName = mkOption {
      type = types.str;
      default = "";
      description = "Reality SNI for this transport";
    };
    path = mkOption {
      type = types.str;
      default = "/vl-xhttp";
      description = "xHTTP path";
    };
    auth = {
      name = mkOption { type = types.str; default = ""; description = "Username (informational)"; };
      uuid = mkOption { type = types.str; description = "UUID for authentication"; };
    };
  };

  relayInboundOptions = {
    sni = mkOption {
      type = types.str;
      description = "SNI for relay xHTTP inbound (must differ from server's xHTTP SNI)";
    };
  };

  relayTargetOptions = {
    enable = mkEnableOption "relay outbound VLESS over xHTTP";
    serverName = mkOption {
      type = types.str;
      default = "";
      description = "Reality SNI for relay outbound xHTTP";
    };
    path = mkOption {
      type = types.str;
      default = "/vl-xhttp";
      description = "xHTTP path of target server";
    };
  };

  subscriptionUpstreamOptions = {
    enable = mkEnableOption "advertise VLESS+xHTTP in generated subscriptions";
    sni = mkOption { type = types.str; description = "Reality SNI for xHTTP"; };
    path = mkOption { type = types.str; default = "/vl-xhttp"; description = "xHTTP path"; };
  };

  mkServerInbound =
    { cfg, clients, shortIds }:
    {
      listen = "127.0.0.1";
      port = 9002;
      protocol = "vless";
      tag = "vless-xhttp-in";
      settings = {
        clients = clients.noFlow;
        decryption = "none";
      };
      streamSettings = {
        network = "xhttp";
        security = "reality";
        realitySettings = helpers.mkRealityServerSettings { inherit (cfg) sni; inherit shortIds; };
        xhttpSettings = { path = cfg.path; };
        sockopt.acceptProxyProtocol = true;
      };
    };

  mkRelayInbound =
    { cfg, serverCfg, clients, shortIds }:
    {
      listen = "127.0.0.1";
      port = 9012;
      protocol = "vless";
      tag = "vless-xhttp-fwd-in";
      settings = {
        clients = clients.noFlow;
        decryption = "none";
      };
      streamSettings = {
        network = "xhttp";
        security = "reality";
        realitySettings = helpers.mkRealityServerSettings { inherit (cfg) sni; inherit shortIds; };
        xhttpSettings = { path = serverCfg.path; };
        sockopt.acceptProxyProtocol = true;
      };
    };

  mkClientOutbound =
    { cfg, realityCfg }:
    helpers.mkVnextOutbound {
      tag = "vless-xhttp-out";
      address = cfg.server;
      port = cfg.port;
      uuid = cfg.auth.uuid;
      streamSettings = {
        network = "xhttp";
        security = "reality";
        realitySettings = helpers.mkRealityClientSettings {
          reality = realityCfg;
          serverName = cfg.serverName;
        };
        xhttpSettings = { path = cfg.path; };
      };
    };

  mkRelayOutbound =
    { cfg, targetCfg, realityCfg, user, serverAddr }:
    helpers.mkVnextOutbound {
      tag = "relay-xhttp-out";
      address = serverAddr;
      port = 443;
      uuid = user.uuid;
      streamSettings = {
        network = "xhttp";
        security = "reality";
        realitySettings = helpers.mkRealityClientSettings {
          reality = realityCfg;
          serverName = cfg.serverName;
        };
        xhttpSettings = { path = cfg.path; };
      };
    };

  mkSubscriptionEntry =
    {
      serverAddr,
      uuid,
      fingerprint,
      realityPublicKey,
      shortId,
      cfg,
    }:
    helpers.mkVlessUri {
      inherit uuid;
      addr = serverAddr;
      port = 443;
      params = {
        encryption = "none";
        security = "reality";
        type = "xhttp";
        path = cfg.path;
        sni = cfg.sni;
        pbk = realityPublicKey;
        sid = shortId;
        fp = fingerprint;
      };
      tag = "vless-xhttp";
    };
}
```

- [ ] **Step 2: Syntax check**

Run:
```bash
nix-instantiate --parse roles/network/xray/transports/xhttp.nix >/dev/null && echo OK
```
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add roles/network/xray/transports/xhttp.nix
git commit -m "feat(xray): add xhttp transport module"
```

---

## Task 5: Create `transports/default.nix` registry

**Files:**
- Create: `roles/network/xray/transports/default.nix`

- [ ] **Step 1: Write the registry**

```nix
# roles/network/xray/transports/default.nix
#
# Transport registry: the single place where transport modules are registered.
# To add a new transport protocol: create a new file in this directory, then
# append one line to the `modules` list below.
#
# Consumers (server.nix, client.nix, relay.nix, subscriptions.nix) fold over
# the returned attrset — adding a protocol should not require edits anywhere
# else.
{ lib }:

let
  helpers = import ./lib.nix { inherit lib; };

  modules = [
    ./tcp.nix
    ./grpc.nix
    ./xhttp.nix
  ];

  loadModule =
    path:
    let
      m = import path { inherit lib helpers; };
    in
    lib.nameValuePair m.name m;
in
lib.listToAttrs (map loadModule modules)
```

- [ ] **Step 2: Evaluate the registry**

Run:
```bash
nix eval --impure --json --expr '
  let
    lib = (import <nixpkgs> {}).lib;
    t = import ./roles/network/xray/transports { inherit lib; };
  in lib.attrNames t
'
```
Expected: `["vlessGrpc","vlessTcp","vlessXhttp"]`.

- [ ] **Step 3: Commit**

```bash
git add roles/network/xray/transports/default.nix
git commit -m "feat(xray): add transports registry"
```

---

## Task 6: Refactor `server.nix` to fold over the registry

**Files:**
- Modify: `roles/network/xray/server.nix` (full rewrite)

- [ ] **Step 1: Rewrite `server.nix`**

Replace entire file contents with:

```nix
# roles/network/xray/server.nix
#
# Defines roles.xray.server options and exports _serverConfig fragment by
# folding over the transport registry. The coordinator (default.nix) still
# owns systemd, nginx, and firewall.
{
  config,
  lib,
  ...
}:

with lib;

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

  enabledTransports = lib.filter (t: cfg.${t.name}.enable) transportList;

  serverConfig = {
    inbounds = map (t: t.mkServerInbound {
      cfg = cfg.${t.name};
      inherit clients shortIds;
    }) enabledTransports;

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
          inboundTag = map (t: "${t.tagPrefix}-in") enabledTransports;
          outboundTag = "direct-out";
        }
      ];
      balancers = [ ];
    };

    nginxSniEntries = map (t: {
      sni = cfg.${t.name}.sni;
      port = t.serverPort;
    }) enabledTransports;
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

      publicKey = mkOption {
        type = types.str;
        default = "";
        description = "Reality public key (public, not secret). Required when subscriptions are enabled.";
      };
    };

    publicAddress = mkOption {
      type = types.str;
      default = "";
      description = "Public hostname clients use to reach this xray server. Required when subscriptions are enabled.";
    };
  } // lib.mapAttrs (_: t: t.serverOptions) transports;

  config = mkIf (config.roles.xray.enable && cfg.enable) {
    assertions = [
      {
        assertion = (secrets.xray.reality.shortIds or [ ]) != [ ];
        message = "secrets.xray.reality.shortIds must be set before deploying xray server";
      }
      {
        assertion = lib.any (t: cfg.${t.name}.enable) transportList;
        message = "At least one xray server transport must be enabled";
      }
      {
        assertion = !cfg.vlessGrpc.enable || !(lib.hasPrefix "/" cfg.vlessGrpc.serviceName);
        message = "roles.xray.server.vlessGrpc.serviceName must not start with '/'";
      }
    ];

    roles.xray._serverConfig = serverConfig;
  };
}
```

- [ ] **Step 2: Evaluate — expect a failure because `options.nix` still exists and duplicates schema**

Run:
```bash
nix eval .#nixosConfigurations.veles.config.roles.xray._serverConfig 2>&1 | head -20
```
Expected: likely a "The option `roles.xray.server.vlessTcp` has conflicting definitions" or similar — because old `client.nix`/`relay.nix` still `import ./options.nix`. That's OK for this intermediate step; we'll unwind it in Tasks 7–9.

If you instead get a clean eval, even better — proceed to Step 3.

- [ ] **Step 3: Commit**

```bash
git add roles/network/xray/server.nix
git commit -m "refactor(xray): fold server.nix over transport registry"
```

---

## Task 7: Refactor `client.nix` to fold over the registry

**Files:**
- Modify: `roles/network/xray/client.nix` (full rewrite)

- [ ] **Step 1: Rewrite `client.nix`**

```nix
# roles/network/xray/client.nix
#
# Defines roles.xray.client options. Runs its own xray process (independent
# from server/relay). Built by folding over the transport registry.
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.roles.xray.client;
  transports = import ./transports { inherit lib; };
  transportList = lib.attrValues transports;

  enabledTransports = lib.filter (t: cfg.${t.name}.enable) transportList;

  realityCfg = cfg.reality;

  xrayConfig = {
    log = { loglevel = "info"; };

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
      (map (t: t.mkClientOutbound {
        cfg = cfg.${t.name};
        inherit realityCfg;
      }) enabledTransports)
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
          selector = map (t: "${t.tagPrefix}-out") enabledTransports;
          strategy = { type = "random"; };
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

    reality = {
      enable = mkEnableOption "Reality TLS";
      publicKey = mkOption { type = types.str; default = ""; description = "Server's Reality public key"; };
      shortId = mkOption { type = types.str; default = ""; description = "Authorized shortId"; };
      serverName = mkOption { type = types.str; default = ""; description = "Fallback SNI"; };
      fingerprint = mkOption { type = types.str; default = "chrome"; description = "uTLS fingerprint"; };
    };
  } // lib.mapAttrs (_: t: t.clientOptions) transports;

  config = mkIf (config.roles.xray.enable && cfg.enable) {
    assertions = [
      {
        assertion = lib.any (t: cfg.${t.name}.enable) transportList;
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
        message = "roles.xray.client.reality.{publicKey,shortId,serverName,fingerprint} must be set when reality.enable = true";
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

- [ ] **Step 2: Commit (intermediate state — eval may still fail until Task 8 + 9)**

```bash
git add roles/network/xray/client.nix
git commit -m "refactor(xray): fold client.nix over transport registry"
```

---

## Task 8: Refactor `relay.nix` to fold over the registry

**Files:**
- Modify: `roles/network/xray/relay.nix` (full rewrite)

- [ ] **Step 1: Rewrite `relay.nix`**

```nix
# roles/network/xray/relay.nix
#
# Defines roles.xray.relay options and exports _relayConfig fragment.
# Relay inbounds are gated on the server's corresponding transport being
# enabled (to reuse server's serviceName/path/shortIds). Relay outbounds
# are gated independently via cfg.target.<transport>.enable.
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

  # Inbounds: gated on server transport being enabled (relay inbounds reuse
  # server's per-transport config such as grpc serviceName / xhttp path).
  enabledInbound = lib.filter (t: serverCfg.${t.name}.enable) transportList;

  # Outbounds: gated independently on cfg.target.<transport>.enable.
  enabledOutbound = lib.filter (t: cfg.target.${t.name}.enable) transportList;

  relayConfig = {
    inbounds = map (t: t.mkRelayInbound {
      cfg = cfg.${t.name};
      serverCfg = serverCfg.${t.name};
      inherit clients shortIds;
    }) enabledInbound;

    outbounds = map (t: t.mkRelayOutbound {
      cfg = cfg.target.${t.name};
      targetCfg = cfg.target;
      realityCfg = cfg.target.reality;
      user = cfg.user;
      serverAddr = cfg.target.server;
    }) enabledOutbound;

    routing = {
      rules = lib.optionals (enabledInbound != [ ]) [
        {
          type = "field";
          inboundTag = map (t:
            if t.name == "vlessGrpc" then "vless-grpcFwd-in"
            else "${t.tagPrefix}-fwd-in"
          ) enabledInbound;
          balancerTag = "relay-balancer";
        }
      ];
      balancers = lib.optionals (enabledOutbound != [ ]) [
        {
          tag = "relay-balancer";
          selector = map (t: "relay-${lib.removePrefix "vless-" t.tagPrefix}-out") enabledOutbound;
          strategy = { type = "leastPing"; };
        }
      ];
    };

    nginxSniEntries = map (t: {
      sni = cfg.${t.name}.sni;
      port = t.relayPort;
    }) enabledInbound;
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

      reality = {
        publicKey = mkOption { type = types.str; default = ""; description = "Target server's Reality public key"; };
        shortId = mkOption { type = types.str; default = ""; description = "Authorized shortId"; };
        serverName = mkOption { type = types.str; default = ""; description = "Fallback SNI"; };
        fingerprint = mkOption { type = types.str; default = "chrome"; description = "uTLS fingerprint"; };
      };
    } // lib.mapAttrs (_: t: t.relayTargetOptions) transports;
  } // lib.mapAttrs (_: t: t.relayInboundOptions) transports;

  config = mkIf (config.roles.xray.enable && cfg.enable) {
    assertions = [
      {
        assertion = config.roles.xray.server.enable;
        message = "roles.xray.relay requires roles.xray.server to be enabled";
      }
      {
        assertion = enabledOutbound != [ ];
        message = "At least one relay target transport must be enabled (roles.xray.relay.target.<transport>.enable)";
      }
      {
        assertion = enabledInbound != [ ];
        message = "At least one server transport must be enabled for relay inbounds";
      }
    ];

    roles.xray._relayConfig = relayConfig;
  };
}
```

- [ ] **Step 2: Delete `options.nix`**

Run:
```bash
git rm roles/network/xray/options.nix
```
Expected: file deleted.

- [ ] **Step 3: Evaluate both hosts**

Run:
```bash
nix eval .#nixosConfigurations.veles.config.roles.xray._serverConfig.inbounds 2>&1 | head -5
nix eval .#nixosConfigurations.buyan.config.roles.xray._serverConfig.inbounds 2>&1 | head -5
```
Expected: both return attrset lists (no errors). If an error mentions a missing option or conflicting definition, stop and fix it before continuing.

- [ ] **Step 4: Commit**

```bash
git add roles/network/xray/relay.nix roles/network/xray/options.nix
git commit -m "refactor(xray): fold relay.nix over transport registry; delete options.nix"
```

---

## Task 9: Verify JSON equivalence against baseline

**Files:**
- (no file changes)

- [ ] **Step 1: Regenerate post-refactor JSON for both hosts**

Run:
```bash
mkdir -p /tmp/xray-after
for host in veles buyan; do
  nix eval --raw .#nixosConfigurations.$host.config.systemd.services.xray.script > /tmp/xray-after/$host.script
  tpl=$(grep -oE '/nix/store/[^ ]+-xray-config-template\.json' /tmp/xray-after/$host.script | head -1)
  nix-store --realise "$tpl" >/dev/null
  jq -S . "$tpl" > /tmp/xray-after/$host.json
done
```
Expected: two normalized JSON files.

- [ ] **Step 2: Diff against baseline**

Run:
```bash
for host in veles buyan; do
  echo "== $host =="
  diff -u /tmp/xray-baseline/$host.json /tmp/xray-after/$host.json || true
done
```
Expected: **empty diff for both hosts.** If there are differences, inspect:

- Tag naming (`vless-grpcFwd-in` vs `vless-grpc-fwd-in`): Task 8 preserves the odd `grpcFwd` name in the inbound-tag list to match pre-refactor behavior. If diff shows this, it's a bug — fix in `relay.nix`.
- Attribute ordering: `jq -S` already sorts keys, so ordering diffs are real diffs.
- Missing keys on server routing rules: server had a single rule merging all inbound tags; refactor should produce the same.

Fix inline until diff is empty for both hosts.

- [ ] **Step 3: Build both hosts fully**

Run:
```bash
nix build .#nixosConfigurations.veles.config.system.build.toplevel --no-link
nix build .#nixosConfigurations.buyan.config.system.build.toplevel --no-link
```
Expected: both succeed.

- [ ] **Step 4: Commit (only if Step 2 required additional fixes)**

If fixes were needed:
```bash
git add -u roles/network/xray/
git commit -m "fix(xray): preserve pre-refactor tag/routing shape for byte-equivalent output"
```
Otherwise skip.

---

## Task 10: Run `nix flake check`

**Files:**
- (no file changes)

- [ ] **Step 1: Run flake check**

Run:
```bash
nix flake check
```
Expected: exits 0. If any eval errors surface, fix and re-run.

- [ ] **Step 2: No commit needed unless fixes applied**

---

## Task 11: Create `subscriptions.nix` submodule

**Files:**
- Create: `roles/network/xray/subscriptions.nix`

- [ ] **Step 1: Write `subscriptions.nix`**

```nix
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

  enabledUpstreamTransports = lib.filter (t: cfg.upstream.${t.name}.enable) transportList;

  shortIdHead =
    if (secrets.xray.reality.shortIds or [ ]) != [ ]
    then builtins.head secrets.xray.reality.shortIds
    else "";

  # Build one user's newline-joined list of vless:// URIs.
  userUrisText =
    user:
    let
      uris = map (t: t.mkSubscriptionEntry {
        serverAddr = cfg.upstream.publicAddress;
        uuid = user.uuid;
        fingerprint = cfg.fingerprint;
        realityPublicKey = cfg.upstream.realityPublicKey;
        shortId = shortIdHead;
        cfg = cfg.upstream.${t.name};
      }) enabledUpstreamTransports;
    in
    lib.concatStringsSep "\n" uris;

  subscriptionsDir = pkgs.runCommand "xray-subscriptions" { } (
    ''
      mkdir -p $out
    ''
    + lib.concatMapStrings (u: ''
      printf '%s' ${lib.escapeShellArg (userUrisText u)} | base64 -w0 > $out/${u.uuid}
    '') secrets.singBoxUsers
  );

  listenPort = if coLocated then 8444 else 443;
  listenAddr = if coLocated then "127.0.0.1" else "0.0.0.0";
in
{
  options.roles.xray.subscriptions = {
    enable = mkEnableOption "serve per-user xray subscriptions over HTTPS";

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
    } // lib.mapAttrs (_: t: t.subscriptionUpstreamOptions) transports;
  };

  config = mkIf (config.roles.xray.enable && cfg.enable) {
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
      // lib.mapAttrs (name: t:
        let sCfg = serverCfg.${name}; in
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
  };
}
```

- [ ] **Step 2: Syntax check**

Run:
```bash
nix-instantiate --parse roles/network/xray/subscriptions.nix >/dev/null && echo OK
```
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add roles/network/xray/subscriptions.nix
git commit -m "feat(xray): add subscriptions submodule (derivation + nginx vhost)"
```

---

## Task 12: Wire `subscriptions.nix` into `default.nix`

**Files:**
- Modify: `roles/network/xray/default.nix`

- [ ] **Step 1: Add import**

Edit `roles/network/xray/default.nix` — update the `imports` list:

```nix
  imports = [
    ./server.nix
    ./client.nix
    ./relay.nix
    ./subscriptions.nix
  ];
```

- [ ] **Step 2: Extend the stream SNI map to route subscription SNI to 127.0.0.1:8444 when co-located**

In `default.nix`, find the `allNginxEntries` let-binding and the `streamConfig` block. Change them so subscriptions contribute an entry.

Add to the `let` block near the existing `allNginxEntries`:

```nix
  subsCfg = config.roles.xray.subscriptions;
  subsCoLocated = cfg.server.enable && subsCfg.enable;
  subsStreamEntry = lib.optionals subsCoLocated [
    { sni = subsCfg.sni; port = 8444; }
  ];
  allNginxEntries =
    serverConfig.nginxSniEntries
    ++ relayConfig.nginxSniEntries
    ++ subsStreamEntry;
```

(Replace the existing `allNginxEntries` binding with this one — keep the other definitions unchanged.)

- [ ] **Step 3: Make the nginx stream block kick in when subscriptions are co-located even if server.enable is false**

Find the `services.nginx = mkIf cfg.server.enable { ... };` block in `default.nix`. Change the guard to:

```nix
    services.nginx = mkIf (cfg.server.enable || subsCoLocated) {
```

This ensures the stream map is set up whenever either server or co-located subscriptions need it. The http virtualhost added by `subscriptions.nix` will then be reachable through the stream proxy.

- [ ] **Step 4: Evaluate `veles` (server-only, subscriptions disabled — should be byte-identical to Task 9 output)**

Run:
```bash
nix eval --raw .#nixosConfigurations.veles.config.systemd.services.xray.script > /tmp/xray-after/veles.script.2
tpl=$(grep -oE '/nix/store/[^ ]+-xray-config-template\.json' /tmp/xray-after/veles.script.2 | head -1)
nix-store --realise "$tpl" >/dev/null
jq -S . "$tpl" > /tmp/xray-after/veles.json.2
diff /tmp/xray-baseline/veles.json /tmp/xray-after/veles.json.2
```
Expected: empty diff.

- [ ] **Step 5: Commit**

```bash
git add roles/network/xray/default.nix
git commit -m "feat(xray): wire subscriptions into coordinator stream routing"
```

---

## Task 13: Smoke-test subscription derivation with a dummy host

**Files:**
- (no persistent file changes — ephemeral test via --impure expression)

- [ ] **Step 1: Verify the subscriptionsDir derivation builds for a host that has subscriptions enabled**

Pick `veles` as the co-location test host. Temporarily enable subscriptions by editing `machines/veles/default.nix`:

Add inside `roles.xray = { ... };`:

```nix
    server = {
      # ... existing fields ...
      publicAddress = "veles.example.com";
      reality.publicKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    };
    subscriptions = {
      enable = true;
      sni = "config.example.com";
      cert = "/etc/nixos/secrets/xray-config-cert.pem";
      key = "/etc/nixos/secrets/xray-config-key.pem";
    };
```

(Do NOT commit this yet — it's a smoke test.)

- [ ] **Step 2: Build the subscription derivation**

Run:
```bash
nix build --impure --expr '
  (builtins.getFlake (toString ./.)).nixosConfigurations.veles.config.systemd.services.nginx.serviceConfig
' 2>&1 | tail -5
```
…or more directly:
```bash
nix eval --raw .#nixosConfigurations.veles.config.services.nginx.virtualHosts."config.example.com".locations."~ ^/xray-config/(?<sub_uuid>[A-Za-z0-9-]+)$".extraConfig
```
Expected: output contains `alias /nix/store/...-xray-subscriptions/$sub_uuid;`.

- [ ] **Step 3: Realise the subscriptions dir and inspect one user file**

Run:
```bash
store_path=$(nix eval --raw .#nixosConfigurations.veles.config.services.nginx.virtualHosts."config.example.com".locations."~ ^/xray-config/(?<sub_uuid>[A-Za-z0-9-]+)$".extraConfig | grep -oE '/nix/store/[^/]+-xray-subscriptions')
nix-store --realise "$store_path"
ls "$store_path"
uuid=$(ls "$store_path" | head -1)
cat "$store_path/$uuid" | base64 -d
```
Expected: a non-empty directory containing one file per user in `secrets.singBoxUsers`. Decoded contents show three `vless://` URIs — one for each of tcp/grpc/xhttp.

- [ ] **Step 4: Sanity-check the URIs**

Each line should:
- Start with `vless://<uuid>@veles.example.com:443?`
- Include `security=reality`
- Include `pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA`
- Include `sni=api.oneme.ru` (tcp), `sni=avatars.mds.yandex.net` (grpc), `sni=onlymir.ru` (xhttp)
- End with `#vless-tcp`, `#vless-grpc`, or `#vless-xhttp`

- [ ] **Step 5: Revert the smoke-test changes to veles**

Run:
```bash
git checkout machines/veles/default.nix
```
Expected: `machines/veles/default.nix` back to its pre-smoke-test contents.

- [ ] **Step 6: No commit.**

---

## Task 14: Update machine configs — enable subscriptions on `veles`

**Files:**
- Modify: `machines/veles/default.nix`

This task is optional — include it only if the real deployment should start serving subscriptions from `veles` immediately. If not, skip to Task 15 and the user can opt-in later.

- [ ] **Step 1: Add real `publicAddress` and `reality.publicKey` to veles server config**

Edit `machines/veles/default.nix`, add inside `roles.xray.server`:

```nix
      publicAddress = "<real hostname>";
      reality.publicKey = "<real reality public key>";
```

Values come from the user — DO NOT invent them.

- [ ] **Step 2: Add subscription block**

Inside `roles.xray = { ... };`, add:

```nix
    subscriptions = {
      enable = true;
      sni = "<real config SNI>";
      cert = "<real cert path>";
      key  = "<real key path>";
    };
```

- [ ] **Step 3: Build**

Run:
```bash
nix build .#nixosConfigurations.veles.config.system.build.toplevel --no-link
```
Expected: success.

- [ ] **Step 4: Commit**

```bash
git add machines/veles/default.nix
git commit -m "feat(veles): enable xray subscription serving"
```

---

## Task 15: Run `nix flake check` and final verification

**Files:**
- (none)

- [ ] **Step 1: Flake check**

Run:
```bash
nix flake check
```
Expected: exits 0.

- [ ] **Step 2: Build all hosts that import xray**

Run:
```bash
for host in veles buyan; do
  echo "== $host =="
  nix build .#nixosConfigurations.$host.config.system.build.toplevel --no-link
done
```
Expected: both succeed.

- [ ] **Step 3: Final JSON diff against baseline (should still be empty for any host that has NOT enabled subscriptions)**

Run:
```bash
for host in veles buyan; do
  nix eval --raw .#nixosConfigurations.$host.config.systemd.services.xray.script > /tmp/xray-final/$host.script 2>/dev/null || mkdir -p /tmp/xray-final
done
mkdir -p /tmp/xray-final
for host in veles buyan; do
  nix eval --raw .#nixosConfigurations.$host.config.systemd.services.xray.script > /tmp/xray-final/$host.script
  tpl=$(grep -oE '/nix/store/[^ ]+-xray-config-template\.json' /tmp/xray-final/$host.script | head -1)
  nix-store --realise "$tpl" >/dev/null
  jq -S . "$tpl" > /tmp/xray-final/$host.json
  echo "== $host =="
  diff /tmp/xray-baseline/$host.json /tmp/xray-final/$host.json || true
done
```
Expected:
- `buyan`: empty diff (no subscriptions enabled).
- `veles`: empty diff if Task 14 was skipped. If Task 14 ran, the `xray.json` (xray's own runtime config) should still match — subscriptions only affect nginx, not the xray process config.

- [ ] **Step 4: No commit unless fixes applied.**

---

## Self-Review Notes

- **Spec coverage:** Tasks 1–10 implement Sections 1–3 and 4 (refactor). Tasks 11–12 implement Section 5 (subscription distribution + nginx co-location). Task 13 verifies the subscription derivation path end-to-end. Task 14 applies it to a real host. Task 15 is final verification.
- **`client.nix` reality options**: The original `options.nix` defined `mkRealityClientOptions` that was used by both `client` and `relay.target`. Task 7 inlines the reality schema into `client.nix` and Task 8 inlines it into `relay.nix`. This duplicates ~6 lines but avoids resurrecting `options.nix` — acceptable since the schema is stable and short.
- **`grpcFwd` tag preservation**: Task 8's routing-rule `inboundTag` mapper keeps the odd `vless-grpcFwd-in` spelling (via the inline conditional) to preserve byte-equivalence with the pre-refactor output. Task 9 Step 2 will catch any drift.
- **Subscriptions on co-located host**: Default wiring uses `mkDefault` so users can override per-transport upstream values without disabling the mirror. The `enable` of each upstream transport defaults to the local server's `enable` — a user who has `server.vlessXhttp.enable = false` won't advertise xHTTP in subscriptions.
- **ACME**: Out of scope per spec. Task 11 takes explicit cert/key paths.
- **Two-phase Task 9 diff**: if the diff surfaces anything, fix in place and re-diff. No new task needed.

---

Plan complete and saved to `docs/superpowers/plans/2026-04-07-xray-transport-modules.md`. Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
