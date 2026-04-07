# Xray Transport Modules Refactor + Per-User Config Distribution

**Date:** 2026-04-07
**Status:** Draft

## Problem

`roles/network/xray/` has grown three sibling files (`server.nix`, `client.nix`, `relay.nix`) that each hand-roll VLESS+Reality inbounds and outbounds for three transports (TCP+Vision, gRPC, xHTTP). Adding a new transport today means coordinated edits across:

- `options.nix` — schema fragments
- `server.nix` — inbound, routing rule, nginx SNI entry
- `client.nix` — outbound, balancer selector
- `relay.nix` — inbound (gated on server), outbound (independent), balancer

Two specific duplication hotspots:

1. **Inbound construction** is duplicated between `server.nix` and `relay.nix`. Both build VLESS+Reality inbounds with `sockopt.acceptProxyProtocol = true`, differing only in port, SNI, tag, and per-transport stream extras.
2. **Outbound-to-xray-server construction** is duplicated between `client.nix` (`mkStreamSettings` + the outbound) and `relay.nix` (`mkTargetStreamSettings` + the outbound). Both build VLESS vnext outbounds with Reality streamSettings, differing only in per-transport stream extras.

Separately, there is no mechanism to distribute client configuration to mobile apps. Users today must be provisioned manually with credentials, SNIs, Reality public key, and shortIds out-of-band.

## Goals

1. **One-file protocol addition.** Adding a new transport protocol should require creating a single new file and adding one line to a registry — no edits to `server.nix`/`client.nix`/`relay.nix`.
2. **Eliminate the inbound and outbound duplication** between server/relay and client/relay.
3. **Per-user subscription distribution.** Generate a base64 vless-URI subscription per user at build time and serve it via nginx on the server host at `https://<config-host>/xray-config/<uuid>`, reusing the existing 443 SNI-routing strategy.
4. **No behavior change for existing deployments.** The generated xray runtime config should be equivalent (modulo attribute ordering) before and after the refactor.

## Non-Goals

- Adding new transport protocols in this change. (Kuma: TCP+Vision, gRPC, xHTTP stay.)
- Short-lived tokens, signed URLs, per-device revocation, or any auth beyond the UUID-in-path scheme.
- Supporting subscription formats other than base64-encoded vless:// URIs (F1).
- Runtime generation of subscriptions. Everything is eval-time + build-time.
- Refactoring the coordinator's systemd/nginx/firewall ownership in `default.nix`. That structure stays.

## Design

### File layout

```
roles/network/xray/
  default.nix            # coordinator (systemd, nginx stream + http, firewall) — largely unchanged
  server.nix             # folds over enabled transports to build _serverConfig
  client.nix             # folds over enabled transports to build services.xray config
  relay.nix              # folds over enabled transports to build _relayConfig
  subscriptions.nix      # per-user subscription derivation + nginx vhost (independent sibling module)
  transports/
    default.nix          # { lib }: { vlessTcp = import ./tcp.nix { ... }; ... } — registry
    lib.nix              # shared helpers: mkRealityServerSettings, mkRealityClientStreamSettings, mkVnextOutbound, vlessUri
    tcp.nix              # VLESS + TCP + Vision
    grpc.nix             # VLESS + gRPC
    xhttp.nix            # VLESS + xHTTP
  # options.nix is deleted — schema moves into transport modules
```

`transports/default.nix` is the single registration point. Adding a protocol = create `transports/<name>.nix` + add one line to `default.nix`.

### Transport module interface

Each `transports/<name>.nix` is a function `{ lib, helpers }: { ... }` returning an attrset with:

```nix
{
  # --- Identity ---
  name        = "vlessTcp";   # attr key used under roles.xray.{server,client,relay,relay.target}
  tagPrefix   = "vless-tcp";  # used for inbound/outbound tags ("vless-tcp-in", "vless-tcp-out", "vless-tcp-fwd-in")
  serverPort  = 9000;         # loopback port for server inbound
  relayPort   = 9010;         # loopback port for relay inbound (server-side forwarding inbound)

  # --- Option schema fragments ---
  serverOptions       = { ... };   # merged into options.roles.xray.server.<name>
  clientOptions       = { ... };   # merged into options.roles.xray.client.<name>
  relayInboundOptions = { ... };   # merged into options.roles.xray.relay.<name>
  relayTargetOptions  = { ... };   # merged into options.roles.xray.relay.target.<name>

  # --- Builders (return xray config fragments) ---
  mkServerInbound  = { cfg, clients, shortIds }: <inbound attrset>;
  mkRelayInbound   = { cfg, serverCfg, clients, shortIds }: <inbound attrset>;
  mkClientOutbound = { cfg, realityCfg }: <outbound attrset>;
  mkRelayOutbound  = { cfg, targetCfg, realityCfg, user, serverAddr }: <outbound attrset>;

  # --- Subscription (per-user vless URI for this transport) ---
  mkSubscriptionEntry = {
    serverAddr,           # roles.xray.server.publicAddress
    uuid,                 # from secrets.singBoxUsers
    fingerprint,          # uTLS fingerprint default
    realityPublicKey,
    shortId,
    cfg,                  # roles.xray.server.<name> — sni, serviceName, path, etc.
  }: "vless://...";
}
```

`helpers` (from `transports/lib.nix`) carries:

- `mkRealityServerSettings { sni, shortIds }` — the `realitySettings` block used in server/relay inbounds (privateKey is still injected at runtime by the coordinator).
- `mkRealityClientStreamSettings { reality, serverName }` — the streamSettings Reality block used when connecting TO an xray server.
- `mkVnextOutbound { tag, address, port, uuid, flow ? null, streamSettings }` — VLESS vnext outbound wrapper.
- `vlessUriParams { uuid, addr, port, params, tag }` — builds a `vless://...?...#tag` URI from a params attrset.

With these helpers, each transport module is expected to be ~60–100 lines.

### Schema wiring

`server.nix`, `client.nix`, `relay.nix` each assemble their option tree by merging transport-provided fragments:

```nix
let
  transports = import ./transports { inherit lib; };  # attrset keyed by name
in
{
  options.roles.xray.server = {
    enable = mkEnableOption "xray server";
    reality = { privateKeyFile = ...; };
    publicAddress = mkOption { ... };
    configHost = { ... };  # for subscription serving; see below
  } // lib.mapAttrs (_: t: t.serverOptions) transports;
}
```

Assertions like "at least one transport enabled" become:

```nix
assertion = lib.any (name: config.roles.xray.server.${name}.enable) (lib.attrNames transports);
```

### Config fragment assembly

`server.nix` computes `_serverConfig` by folding over the registry:

```nix
enabledTransports = lib.filter (t: cfg.${t.name}.enable) (lib.attrValues transports);

serverConfig = {
  inbounds  = map (t: t.mkServerInbound { cfg = cfg.${t.name}; inherit clients shortIds; }) enabledTransports;
  outbounds = [ { protocol = "freedom"; tag = "direct-out"; } ];
  routing = {
    rules = [{
      type = "field";
      inboundTag = map (t: "${t.tagPrefix}-in") enabledTransports;
      outboundTag = "direct-out";
    }];
    balancers = [];
  };
  nginxSniEntries = map (t: { sni = cfg.${t.name}.sni; port = t.serverPort; }) enabledTransports;
};
```

`client.nix` and `relay.nix` follow the same folding pattern. Each of the three files ends up ~60–80 lines (down from 200–337 today).

### Subscription distribution

Subscription serving lives in its own submodule `roles.xray.subscriptions`, a sibling of `server`/`client`/`relay`. This lets it run on any host — either co-located with `roles.xray.server` (reusing nginx and the 443 SNI routing) or on a completely different host that only hosts the config endpoint. Multiple subscription hosts can exist for the same upstream server.

**New options** on `roles.xray.server` (needed regardless of where subscriptions run; when subscriptions are hosted elsewhere these values are mirrored via the subscription host's own `upstream` options — see below):

- `publicAddress` — hostname clients connect to (e.g. `vpn.example.com`). Required when any transport is enabled.
- `reality.publicKey` — Reality public key (public, not secret). Required.

**New top-level submodule** `roles.xray.subscriptions`:

```nix
options.roles.xray.subscriptions = {
  enable = mkEnableOption "serve per-user xray subscriptions over HTTPS";

  # How clients reach THIS subscription host
  sni = mkOption {
    type = types.str;
    description = "SNI/hostname of the subscription endpoint (e.g. config.example.com).";
  };

  cert = mkOption { type = types.path; description = "TLS certificate for the subscription vhost."; };
  key  = mkOption { type = types.path; description = "TLS private key for the subscription vhost."; };

  fingerprint = mkOption {
    type = types.str;
    default = "chrome";
    description = "Default uTLS fingerprint embedded in generated vless URIs.";
  };

  # What upstream xray server to advertise in the subscriptions.
  # When subscriptions run on the same host as roles.xray.server, these default
  # to the local server's values via `config` defaults. When run on a different
  # host, they must be set explicitly.
  upstream = {
    publicAddress = mkOption {
      type = types.str;
      description = "Public hostname of the xray server to advertise in generated URIs.";
    };
    realityPublicKey = mkOption {
      type = types.str;
      description = "Reality public key of the upstream xray server.";
    };
    shortIds = mkOption {
      type = types.listOf types.str;
      description = "Reality shortIds accepted by the upstream xray server.";
    };
    # Per-transport upstream config — mirrors the shape of roles.xray.server.<transport>
    # and is populated by transport modules via a new `subscriptionUpstreamOptions` fragment.
  } // lib.mapAttrs (_: t: t.subscriptionUpstreamOptions) transports;
};
```

**When co-located with `roles.xray.server`**, `roles.xray.subscriptions.upstream.*` defaults to the local server's values so the user only needs to set `enable`, `sni`, `cert`, `key`. This is implemented in `subscriptions.nix` using `mkDefault` against `config.roles.xray.server` when `server.enable` is true.

**Transport module addition.** Each transport module gains one more option fragment:

```nix
subscriptionUpstreamOptions = { sni, ... per-transport upstream fields ... };
```

— e.g. tcp needs `sni`, grpc needs `sni` + `serviceName`, xhttp needs `sni` + `path`. `mkSubscriptionEntry` takes its per-transport `cfg` arg from `roles.xray.subscriptions.upstream.<name>` instead of `roles.xray.server.<name>`. This keeps the "add a protocol = one file" property — the subscription upstream schema is owned by the transport module.

**Which transports appear in a user's subscription.** Determined by which `roles.xray.subscriptions.upstream.<name>` entries are enabled on the subscription host, NOT by which server transports are enabled on the local host. Co-located default wires these together; remote hosts declare explicitly.

**Build-time subscription derivation** — lives in `subscriptions.nix` (not `server.nix`):

```nix
subscriptionsDir = pkgs.runCommand "xray-subscriptions" { } ''
  mkdir -p $out
  ${lib.concatMapStrings (u:
    let
      uris = map (t: t.mkSubscriptionEntry {
        serverAddr       = subsCfg.upstream.publicAddress;
        uuid             = u.uuid;
        fingerprint      = subsCfg.fingerprint;
        realityPublicKey = subsCfg.upstream.realityPublicKey;
        shortId          = builtins.head subsCfg.upstream.shortIds;
        cfg              = subsCfg.upstream.${t.name};
      }) enabledUpstreamTransports;
      joined = lib.concatStringsSep "\n" uris;
      b64    = # base64 encode joined in the build script
    in ''
      printf '%s' ${lib.escapeShellArg joined} | base64 -w0 > $out/${u.uuid}
    ''
  ) secrets.singBoxUsers}
'';
```

Files are named by raw UUID. Each file contains the base64-encoded newline-joined vless URIs for all enabled server transports.

**Nginx** (configured by `subscriptions.nix`, not `default.nix`):

Two layouts depending on co-location:

- **Co-located with `roles.xray.server`** — extend the existing stream `$xray_backend` map to route `subsCfg.sni` → `127.0.0.1:8444`, and add an `http{}` virtualhost on `127.0.0.1:8444` ssl. Keeps the single-443-port property.
- **Standalone subscription host** — no stream block needed; just a normal `http{}` virtualhost listening on `0.0.0.0:443` ssl, and a firewall hole for 443. `subscriptions.nix` detects `config.roles.xray.server.enable` and picks the appropriate layout.

```nix
services.nginx.virtualHosts."${subsCfg.sni}" = {
  # listen addrs chosen based on co-location
  sslCertificate     = subsCfg.cert;
  sslCertificateKey  = subsCfg.key;
  locations."~ ^/xray-config/(?<uuid>[A-Za-z0-9-]+)$" = {
    extraConfig = ''
      alias ${subscriptionsDir}/$uuid;
      default_type text/plain;
      autoindex off;
      limit_req zone=xray_config burst=5 nodelay;
      add_header Cache-Control "no-store";
    '';
  };
};

services.nginx.commonHttpConfig = ''
  limit_req_zone $binary_remote_addr zone=xray_config:10m rate=10r/m;
'';
```

Unknown UUIDs return `404` naturally (nginx `alias` with missing file).

The existing nginx stream block on 443 already does `ssl_preread`, so the new `configHost.sni` just needs an entry in the stream `map`. The client's first fetch goes through port 443 exactly like xray traffic — a single exposed port.

### URI construction per transport

Shared params (all transports):
`encryption=none`, `security=reality`, `pbk=<publicKey>`, `sid=<shortId>`, `fp=<fingerprint>`, `sni=<transport sni>`.

Per-transport additions (in `mkSubscriptionEntry`):

- **tcp**: `type=tcp`, `flow=xtls-rprx-vision`
- **grpc**: `type=grpc`, `serviceName=<serviceName>`, `mode=gun` (xray default)
- **xhttp**: `type=xhttp`, `path=<path>`

Fragment (`#...`) is the tagPrefix, giving users readable entries in their client ("vless-tcp", "vless-grpc", "vless-xhttp").

## Migration & Verification

Single PR. Partial migrations would leave the codebase in a non-evaluating state.

**Verification steps:**

1. **Before the refactor**: on a host with server+relay enabled, capture the generated xray config:
   ```
   nix eval --raw .#nixosConfigurations.<host>.config.systemd.services.xray.script > /tmp/before.script
   ```
   And the template JSON it references.
2. **After the refactor** (same host config): capture again as `/tmp/after.script`.
3. Normalize both JSONs with `jq -S` and diff. Expect: either empty diff, or only key-ordering differences.
4. On a relay host, verify `_relayConfig` inbound/outbound count matches pre-refactor expectation.
5. Manual sanity: one host builds, deploys, proxy connectivity works over all enabled transports.

**Subscription-specific verification:**

1. `nix build .#nixosConfigurations.<host>.config...subscriptionsDir` — derivation builds.
2. For one known user, decode the file: `base64 -d $out/<uuid>` → expect N lines of `vless://...` where N = number of enabled server transports.
3. Paste into v2rayNG / Hiddify, verify it connects.
4. `curl -sv https://<configHost.sni>/xray-config/<uuid>` from an external host returns the base64 body.
5. `curl -sv https://<configHost.sni>/xray-config/00000000-0000-0000-0000-000000000000` returns 404.
6. Hit the endpoint >10 times/minute from one IP — subsequent requests get `503`.

## Out of Scope / Future Work

- ACME/Let's Encrypt integration for `configHost`. v1 requires explicit cert paths.
- Rotating subscription tokens decoupled from user UUIDs.
- Subscription formats other than F1 base64-vless.
- Per-device revocation.
- Adding new transport protocols (Trojan, Shadowsocks, Hysteria2, etc.) — the registry makes this easy, but each is its own change.
