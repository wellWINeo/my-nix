# Hysteria2 — Design Spec

## Overview

Add Hysteria2 support to the existing xray proxy infrastructure. Hysteria2 runs
**inside the existing xray process** as an additional inbound protocol
(`protocol: "hysteria"`, QUIC transport) — it is *not* a separate daemon.
xray-core supports hysteria2 as both an inbound (server) and an outbound
(client) natively, so no new binary is required beyond the existing `xray`
package.

Deployment topology mirrors the current VLESS server/relay split:

- **buyan** (NL entry point): a hysteria2 **server inbound** next to the existing
  VLESS+Reality inbounds.
- **veles** (RU relay): a hysteria2 **relay inbound** (accepts clients over QUIC)
  plus an optional hysteria2 **relay outbound** (forwards to buyan over QUIC).

The defining requirement is **protocol mixing at the relay**: a client may
connect to veles over hysteria2 while veles egresses to buyan over *any* of the
enabled relay transports (`{tcp, grpc, xhttp, hy2}`), chosen by the existing
leastPing balancer.

## Key constraint: UDP, not the SNI router

Hysteria2 is UDP/QUIC. It **cannot** traverse the TCP-based SNI router
(`roles/network/sni-router.nix` is nginx stream TCP only). It listens on its own
UDP port, exposed directly by the host firewall, completely independent of the
`443/tcp` Reality front-end. Hysteria2 uses **real TLS** (with optional HTTP/3
masquerade), not REALITY.

## Architecture

```
                    ┌──────────────── buyan (NL) ────────────────┐
                    │  xray process:                              │
                    │   vless-tcp-in, vless-grpc-in, vless-xhttp-in │
                    │   hy2-in  ← NEW (UDP/<port>, TLS, QUIC)     │
                    │   all → direct-out                          │
                    └─────────────────────────────────────────────┘
                                      ▲
        ┌──────── relays via relay-balancer (leastPing) ────────┐
        │                                                       │
┌── veles (RU) ── xray process ─────────────────────────────────┤
│  inbounds (clients connect here):                              │
│    vless-tcp/grpc/xhttp relay inbounds  (existing)             │
│    socks-relay-in                       (existing)             │
│    hy2-relay-in  ← NEW (UDP/<port>)                            │
│  outbounds (to buyan) — balancer pool, MIXED:                  │
│    relay-tcp-out, relay-grpc-out, relay-xhttp-out  (existing)  │
│    relay-hy2-out  ← NEW (optional, QUIC)                       │
│  routing: every relay inbound tag → relay-balancer             │
└────────────────────────────────────────────────────────────────┘
```

Mixing happens at the xray routing layer, which is already protocol-agnostic.
`hy2-relay-in` gets a routing rule to the existing `relay-balancer`; if
`relay-hy2-out` is enabled, its tag joins the balancer's `selector` list. A
client connecting to veles over QUIC can therefore egress to buyan over any of
`{tcp, grpc, xhttp, hy2}`, picked by leastPing — fulfilling
`client --hy2--> veles --any proto--> buyan`.

## Module structure

A single new pure-library file **`roles/network/xray/hysteria.nix`** holds all
hysteria2 protocol logic. It is analogous to `transports/tcp.nix` but is **not**
pushed through the VLESS+REALITY helpers (which assume uuid clients,
`mkVnextOutbound`, and REALITY shortIds). It is folded into the consumers
**alongside** the VLESS `transports/` registry, not added to that registry.

The existing `transports/` registry and its `clients = {withFlow, noFlow}`
pre-shaping are **left untouched** — lower risk than generalizing that VLESS call
boundary. Hysteria2 builders take the raw `users` list (filtered per-host) and
shape their own client entries from `user.password`.

### `hysteria.nix` contract

The module exports:

- `name = "hysteria2"`
- inbound/outbound tag constants: `hy2-in`, `hy2-relay-in`, `relay-hy2-out`
- option-schema fragments: `serverOptions`, `relayInboundOptions`,
  `relayTargetOptions`, `subscriptionUpstreamOptions`
- builders with hysteria-appropriate signatures (password auth, TLS cert — not
  reality):
  - `mkServerInbound { cfg, users }` →
    `{ protocol="hysteria"; settings.version=2; users=[{auth,password,email}];
       streamSettings={network="hysteria"; hysteriaSettings; security="tls";
       tlsSettings}; }`
  - `mkRelayInbound { cfg, users }` → same shape, relay tag/port
  - `mkRelayOutbound { cfg, users, serverAddr }` →
    `{ protocol="hysteria"; tag="relay-hy2-out"; ... }`
  - `mkSubscriptionEntry { cfg, user, serverAddr }` → `hysteria2://` URI

### Consumer integration (small, isolated additions)

- **`server.nix`**: when `cfg.hysteria.enable`, append
  `hysteria.mkServerInbound { inherit users; }` to `inbounds`, add `hy2-in` to
  the server routing rule's `inboundTag` list, and emit **no** `nginxSniEntries`
  entry (UDP).
- **`relay.nix`**: when the hysteria relay inbound is enabled, append
  `mkRelayInbound` to `inbounds` and add `hy2-relay-in` to the relay routing rule
  → `relay-balancer`; when the hysteria relay outbound is enabled, append
  `mkRelayOutbound` to `outbounds` and add `relay-hy2-out` to the balancer's
  `selector`.
- **`subscriptions.nix`**: when the hysteria upstream is enabled, append a
  `hysteria2://` URI per user (using `user.password`) to each user's URI list.

The **coordinator (`default.nix`) needs no routing changes** — it already
concatenates `inbounds`/`outbounds`/`routing.rules`/`balancers` from the
fragments, so hysteria2 flows through the same merge.

## Certificate handling (configurable, with pinning)

- `certFile` / `keyFile` options (`types.path`) — point at on-disk TLS material,
  deployed as **file-based secrets** via the existing `locked.tar.gpg` →
  `make install-secrets` flow to `/etc/nixos/secrets/`, OR at an ACME cert path
  on hosts that have one.
- `pinSHA256` option (optional string) — when set, subscriptions emit
  `pinSHA256=<value>` so clients pin the cert (secure; the same cert file is
  referenced by both the serving host and, via secrets, the subscription
  generator).
- Self-signed fallback: an `autoSelfSigned` flag (default `false`). When
  `certFile`/`keyFile` are unset **and** `autoSelfSigned = true`, a systemd
  one-shot generates a persistent self-signed pair under `/var/lib/hysteria/`.
  The pin is not known at build time in this mode, so subscriptions emit
  `insecure=1`. This is the zero-config path; supplying real cert files is the
  secure path.

## Users / auth — no new secrets

- Hysteria2 `auth` reuses the existing `secrets.singBoxUsers[].password` field
  (already in the schema, already host-filtered via `filterProxyUsersForHost`).
  VLESS uses `uuid`; hysteria2 uses `password` — both pre-exist.
- `email = "${user.name}@hysteria"` for stats/logs, matching the
  `"${name}@xray"` convention.
- `secrets/secrets.dummy.json` needs **no new fields** for users. Cert material
  lives in file-secrets, not JSON.

## Subscription URI

`mkSubscriptionEntry` emits the standard `hysteria2://` scheme:

- pin mode:
  `hysteria2://<password>@<addr>:<port>/?sni=<sni>&pinSHA256=<hash>#<tag>`
- self-signed/insecure mode:
  `hysteria2://<password>@<addr>:<port>/?sni=<sni>&insecure=1#<tag>`
- real-cert mode:
  `hysteria2://<password>@<addr>:<port>/?sni=<domain>#<tag>`

`roles.xray.subscriptions` is built but not enabled on any machine today;
subscription serving is therefore orthogonal to this change. Hysteria2 only
contributes its `mkSubscriptionEntry` builder + the fold into
`subscriptions.nix`. Whenever the role is later enabled (co-located on buyan or
standalone), `upstream.hysteria = { enable=true; sni=...; pinSHA256=...; }`
makes `hysteria2://` lines appear in each user's feed alongside the `vless://`
ones.

## Firewall & systemd

**Firewall.** Hysteria2 is UDP/QUIC on a configurable port (distinct per host;
concrete values picked in machine config to avoid collisions — e.g. veles already
uses `8443/tcp` for the stream-forwarder). Each host opens
`networking.firewall.allowedUDPPorts` for its hysteria2 inbound(s).

**Systemd (coordinator `default.nix`).** The existing xray unit is
`DynamicUser = true` with `LoadCredential` + a `jq` rewrite that injects the
Reality private-key value. Hysteria2 cert/key are surfaced the **same way**: when
a hysteria inbound is enabled, the unit conditionally adds
`LoadCredential = [ "hysteria-cert:..." "hysteria-key:..." ]` and the jq script
injects the credential paths into the hysteria inbound's
`tlsSettings.certificates`. This keeps all secret material out of the Nix store
and consistent with the Reality-key handling — no change to the hardening
posture.

## Machine wiring

**buyan** (`machines/buyan/default.nix`) — hysteria2 server inbound next to the
VLESS ones:

```nix
roles.xray.server.hysteria = {
  enable = true;
  port = 36712;                         # UDP, example
  certFile = /etc/nixos/secrets/hysteria-cert;
  keyFile  = /etc/nixos/secrets/hysteria-key;
  sni = "<camouflage SNI>";
  masquerade = { type = "proxy"; url = "https://..."; };  # optional
  # pinSHA256 = "<sha256>";            # set if cert is pinned for clients
};
```

**veles** (`machines/veles/default.nix`) — relay inbound (serve RU clients over
QUIC) + optional relay outbound (QUIC to buyan, joins the balancer pool):

```nix
roles.xray.relay.hysteria = {
  inbound = {
    enable = true;
    port = 36712;                       # UDP
    certFile = /etc/nixos/secrets/hysteria-cert;
    keyFile  = /etc/nixos/secrets/hysteria-key;
    sni = "<veles hy2 SNI>";
  };
  outbound = {                          # optional — adds relay-hy2-out to the balancer
    enable = true;
    serverName = "<buyan hy2 SNI>";
    pinSHA256 = "<buyan cert pin>";     # or insecure = true
  };
};
```

## Validation & assertions

`make setup-dummy-secrets && make check` (no GPG needed). New assertions:

- hysteria server enabled ⇒ `certFile`/`keyFile` provided (or `autoSelfSigned`
  set).
- relay hysteria inbound enabled ⇒ `certFile`/`keyFile` provided (or
  `autoSelfSigned`).
- relay hysteria outbound enabled ⇒ target server address **and** (`pinSHA256`
  or `insecure`) set.
- hysteria uses `password` auth; ensure at least one `singBoxUsers` entry with a
  non-empty `password` is host-filtered in.
