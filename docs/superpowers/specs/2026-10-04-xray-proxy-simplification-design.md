# Xray Proxy Simplification Design

**Status:** Implemented in this PR; not deployed or live-validated. Supersedes the proposed topology in `2026-10-03-buyan-initiated-reverse-relay-design.md`; leave that older document as historical context. Deployment requires the gates in [the runbook](../../xray-reverse-deployment.md).

## Goal and invariants

Run Veles solely as a proxy relay: clients (including NixPi) enter one VLESS RAW/TCP+Vision, one VLESS gRPC, one VLESS xHTTP, or one Hysteria2 inbound, then leave the internet from Buyan. Buyan keeps its existing public VLESS server. Buyan establishes **two** reverse VLESS+REALITY connections to Veles, RAW and xHTTP. Veles chooses between the two dynamically registered reverse outbounds using an observatory-backed `leastPing` balancer. When neither is healthy, **new proxy requests fail closed**. Existing streams are not retried or migrated. Do not prevent non-Xray host-originated egress from Veles.

Veles's existing forward relay target settings remain configured in Nix, but generate **no Veles-initiated outbounds** in reverse mode. `egress.via = "forward"` is an explicit/manual switch that selects the classic Veles-initiated relay; it is never an automatic reverse fallback. In both modes an unrouteable request must fail rather than egress directly from Veles. Keep TCP/2053 redirected to the existing TCP/443 SNI router for client/forward-backup connectivity, not as a separate backend. Do not introduce new public ports or a second Xray process.

Remove MTProxy (telemt service, role, Veles's telemt overlay and SNI entry) and its local relay SOCKS inbound. Remove the unused Xray subscription generator. Preserve Hysteria2 **server and relay** support, Xray metrics, Buyan's public inbounds, NixPi's SOCKS/HTTP/fixed-destination-tunnel client, the existing SNI router and all non-Xray host services. No new dependencies.

## Topology and mode semantics

```text
NixPi/clients -- VLESS RAW | gRPC | xHTTP | Hysteria2 --> Veles
  Veles egress.via = reverse:
    reverse-raw-out or reverse-xhttp-out (leastPing) -- Buyan-initiated link --> Buyan --> public internet
    neither healthy -> blocked-out (blackhole), never a forward or Veles-direct fallback
  Veles egress.via = forward (manual rollback):
    leastPing over configured Veles-initiated Buyan outbounds -> Buyan --> public internet
    no healthy candidates -> blocked-out

Buyan public VLESS client -> Buyan direct-out -> internet
Buyan reverse-raw-in/reverse-xhttp-in -> reverse-public-out -> public TCP/UDP only
```

Veles's `egress.reverse.user` is nullable. When supplied, it advertises the RAW and xHTTP reverse portal clients **even while `egress.via = "forward"`**, so Buyan's bridge can connect before cutover. `egress.via` chooses only where ordinary inbound traffic is routed. In reverse mode the user is required. When `egress.via = "reverse"`, the entire `egress.forward` subtree is inert: no forward outbounds, forward balancer or forward observatory candidates are emitted; it remains in the machine config for a manual rollback. When `egress.via = "forward"`, generate the chosen RAW/gRPC/xHTTP and optional Hysteria2 forward candidates, including configured backup TCP port, and route only those through `leastPing`. A forward-failure request must never fall back to a freedom outbound on Veles.

On Veles the static first/default outbound is `blocked-out` (`blackhole`). Routing explicitly sends each client-facing VLESS inbound and the relay Hysteria2 inbound (`hy2-relay-in`) to the selected balancer; any unmatched ingress also hits `blocked-out`. Keep the relay Hysteria2 tag distinct from the server tag (`hy2-in`) so runtime certificate dispatch selects the relay credential. The reverse balancer selects the distinct **dynamic** tags `reverse-raw-out` and `reverse-xhttp-out`, with `fallbackTag = "blocked-out"`; the observatory's subject selector includes these tags. Xray creates those outbound handlers only after Buyan has connected: the Nix-generated Veles JSON holds reverse-marked inbound users and tag references, **not static reverse outbounds**. Use a bounded probe interval and require actual observations before declaring healthy. This design depends on runtime tests with the deployed Xray binary; evaluating or syntax-checking JSON cannot prove dynamic registration, probing, TCP/UDP forwarding or rapid recovery.

Buyan's two static bridge outbounds, `bridge-raw-out` and `bridge-xhttp-out`, use the **simplified VLESS outbound settings** (`settings.address`, `port`, `id`, `encryption`, `reverse.tag`; no `vnext[].users[]`) and distinct logical inbound tags `reverse-raw-in` and `reverse-xhttp-in` (paired respectively with `bridge-raw-out` and `bridge-xhttp-out`). RAW uses `flow = "xtls-rprx-vision"` on both the matching Veles inbound client and Buyan outbound; xHTTP uses no Vision flow. The bridge's REALITY SNIs, xHTTP path, public key and short ID must match Veles's corresponding inbound. Use the existing optional ClientHello fragmentation and fixed `firefox` fingerprint for the bridge; do not implicitly change NixPi's or the dormant forward links' current fingerprints. Xray's VLESS reverse protocol, rather than a generic reverse-tunnel framework, implements the link.

Buyan's first/default outbound is also `blocked-out`. Explicit rules route ordinary public server inbounds to `direct-out`, and **only** the two reverse logical inbounds to `reverse-public-out` (`freedom`, `settings.finalRules` allowing `tcp,udp` to `!geoip:private`). Do not use a destination rewrite or allow a reverse connection to inherit unrestricted public-client routing. Confirm denial of loopback, RFC1918, link-local, other reserved ranges and domains resolving to private addresses on the deployed binary; extend deny policy if `geoip:private` does not cover required ranges. This is a security gate, not a claim that the Nix template alone guarantees the result.

## Authentication and secret handling

Use the **existing** `buyan` user from `secrets.singBoxUsers` (already authorized for Veles), selected in machine configs with `common/select-proxy-user.nix`. Both Buyan bridge outbounds use its UUID. Veles receives the filtered normal user list and an explicit `egress.reverse.user`; the role checks that exactly one normal-list entry matches that UUID, removes it from ordinary clients on **all** Veles VLESS/Hysteria2 inbounds, and inserts one reverse-marked client for it on each of RAW and xHTTP. The reverse-marked client must not be duplicated on a given inbound. Buyan cannot use Veles as an ordinary proxy user. Other users remain unaffected. Buyan's *own* public-server users remain unchanged. Do not add a new UUID, `mode` field in secrets, `/etc/nixos/secrets/xray-reverse-uuid` file or dedicated reverse port.

`secrets.json` is imported at Nix evaluation, as today: generated Xray templates can contain normal user UUIDs and Hysteria2 passwords in the Nix store. Do **not** claim these credentials are runtime-only. Avoid printing real credentials in plans, tests or logs; use the committed dummy JSON for evaluation tests. Continue loading the REALITY private key and Hysteria2 TLS certificate/key **files** through systemd `LoadCredential` at runtime, rendering a mode-0600 temporary JSON file and validating it with `xray run -test -format json` before starting. Retain the working explicit `-format json` invocation for extensionless temporary configs.

## Machine-facing interface (proposed)

The NixOS Xray role is machine-agnostic: it does not select `buyan` by name, read `../../../secrets` internally, embed Veles/Buyan addresses or use host-named tags. Exactly one `roles.xray.client.enable`, `.relay.enable` or `.server.enable` may be true on a host; remove redundant `roles.xray.enable`. `roles.xray.metrics.enable` remains valid for relay/server and registers its native metrics endpoint/scrape behavior. `roles.sni-router` entries and firewall rules are owned by the active Xray mode. The machines provide inputs; no machine writes internal registries or generated JSON fragments.

### Veles: `roles.xray.relay`

```nix
roles.xray.relay = {
  enable = true;
  ingress = {
    users = users; # host-filtered, including the reverse user before role exclusion
    reality = {
      privateKeyFile = "/etc/nixos/secrets/xray-reality-private-key";
      shortIds = secrets.xray.reality.shortIds;
    };
    vless = {
      raw.sni = "api.oneme.ru";
      grpc.sni = "avatars.mds.yandex.net";
      xhttp.sni = "onlymir.ru"; # xhttp.path defaults to "/vl-xhttp"
    };
    hysteria2 = {
      enable = true;
      port = 443;
      sni = "turn.webrtc.yandex.net";
      certFile = "/etc/nixos/secrets/hysteria-veles-cert";
      keyFile = "/etc/nixos/secrets/hysteria-veles-key";
      masquerade = { type = "proxy"; url = "https://turn.webrtc.yandex.net"; };
    };
  };
  egress = {
    via = "reverse"; # enum "reverse" | "forward"
    reverse.user = reverseUser; # selectProxyUser "buyan" users in this machine
    forward = {
      user = relayUser;
      server = secrets.ip.buyan.address;
      backupPort = 2053;
      reality = {
        publicKey = secrets.xray.reality.publicKey;
        shortId = builtins.head secrets.xray.reality.shortIds;
        fingerprint = "randomized"; # preserved, not newly recommended
      };
      vless = {
        raw = { enable = true; serverName = "ghcr.io"; };
        grpc = { enable = true; serverName = "update.googleapis.com"; };
        xhttp = { enable = true; serverName = "dl.google.com"; };
      };
      hysteria2 = {
        enable = false;
        serverName = "bing.com";
        insecure = true;
        certificateFingerprint = null;
        port = 36712;
      };
    };
  };
};
```

The `egress.forward.hysteria2.certificateFingerprint` option is `nullOr str`, default `null`: a SHA-256 **remote certificate** pin, distinct from a ClientHello fingerprint. It replaces the existing `pinSHA256` option rather than duplicating it. If this outbound is enabled and a pin is set, `insecure = true` is invalid; `insecure = false` with no pin is allowed for normally trusted certificates. Map the pin to `tlsSettings.pinnedPeerCertSha256` as a single hex string (not an array) for the currently evaluated Xray 26.9.9; verify it with the deployed binary, and test that a mismatched pin fails closed. The currently disabled, insecure configuration above is retained as data, not an endorsement for enabling it.

### Buyan: `roles.xray.server`

```nix
roles.xray.server = {
  enable = true;
  ingress = {
    users = users;
    reality = {
      privateKeyFile = "/etc/nixos/secrets/xray-reality-private-key";
      shortIds = secrets.xray.reality.shortIds;
    };
    vless = {
      raw = { enable = true; sni = "ghcr.io"; };
      grpc = { enable = true; sni = "update.googleapis.com"; };
      xhttp = { enable = true; sni = "dl.google.com"; };
    };
    hysteria2.enable = false; # keep supported server mode
  };
  reverseBridge = {
    enable = true;
    address = secrets.ip.veles.address;
    user = reverseUser; # same selected buyan user as Veles's reverse.user
    reality = {
      publicKey = secrets.xray.reality.publicKey;
      shortId = builtins.head secrets.xray.reality.shortIds;
    };
    vless.raw.serverName = "api.oneme.ru";
    vless.xhttp.serverName = "onlymir.ru";
    # xhttp.path defaults to "/vl-xhttp"; bridge fingerprint defaults to "firefox"
  };
};
```

### NixPi: `roles.xray.client`

```nix
roles.xray.client = {
  enable = true;
  ingress = {
    socks.port = 1081;
    http.enable = true;
    openFirewall = true;
    tunnels = [ { listen = "127.0.0.1:5053"; target = "1.1.1.1:853"; } ];
  };
  egress = {
    server = secrets.ip.veles.address;
    user = nixpiXrayUser;
    backupPort = 2053;
    reality = {
      publicKey = secrets.xray.reality.publicKey;
      shortId = builtins.head secrets.xray.reality.shortIds;
      fingerprint = "randomized"; # preserve existing behavior for this refactor
    };
    vless = {
      raw = { enable = true; serverName = "api.oneme.ru"; };
      grpc = { enable = true; serverName = "avatars.mds.yandex.net"; };
      xhttp = { enable = true; serverName = "onlymir.ru"; };
    };
  };
};
```

Each ingress VLESS group may retain transport-specific options where needed (`grpc.serviceName`, `xhttp.path`); the client egress group uses matching settings. `roles.xray.fragmentClientHello` remains an optional shared knob, defaulting to its current behavior. No extra `ingress.enable`, `egress.enable`, `roles.xray.enable`, `secret mode`, or general-purpose transport registry is needed.

## Module boundaries

Keep `roles/network/xray/default.nix` as the coordinator: import the mode and metrics modules, enforce mutual exclusion, choose the complete generated config, own only shared systemd runtime-secret rendering/startup and the internal read-only `_configTemplate` test seam. `client.nix` owns the complete NixPi Xray client config; `relay.nix` owns Veles's full inbound/egress policy; `server.nix` owns Buyan's full inbound/bridge/direct-versus-reverse policy. Their option names describe capabilities rather than hostnames. `vless.nix` provides a *small* shared builder for VLESS/REALITY inbounds, regular VLESS outbounds and the structurally different simplified reverse outbound; its RAW/gRPC/xHTTP differences are explicit data/branches, not a dynamic registry with five builders per transport. `hysteria.nix` handles Hysteria2 inbound and optional forward outbound; retain both server and relay use. `metrics.nix` keeps the collector and its options; the coordinator adds metrics JSON when enabled, without `_extraConfig` fragment merging. Keep `roles/network/sni-router.nix` separate. Delete `transports/` and `subscriptions.nix` only after their actual consumers have migrated.

No role should select a named host, import `../../../secrets`, or mutate another role's internal registry. Server and relay modes each generate their own SNI entries and Hysteria2 UDP firewall rules. Keep existing client-side TCP/2053 backup behavior and Buyan/Veles port redirects. Update Xray dashboards/tests for generic reverse tags. The source tree must remain evaluable at each implementation checkpoint; do not replace working modes with stubs.

## Verification and staged deployment

- Use dummy secrets in the isolated worktree only; never overwrite an ignored real `secrets/secrets.json`. Run `make check`, `nixfmt --check`/`nixfmt` on changed Nix files, and `bash roles/network/xray/tests/reverse.sh "path:$(pwd -P)"` (or the evolved equivalent). Eval tests inspect all three `_configTemplate` outputs and negative assertions: no Veles direct/SOCKS/MTProxy/duplicate VLESS inbounds, Buyan's normal/public reverse isolation, reverse user absent as ordinary client, correct RAW+Vision/xHTTP and distinct tags, inactive forward settings in reverse mode, forwarding candidates present in forward mode, blackhole fallback, Hysteria2 server and pin/insecure errors, NixPi settings, and exact SNI/path parity. Inspect systemd script and credential paths without exposing live secrets. `make check` alone does **not** execute the Xray-specific shell test.
- Confirm config grammar with the deployed Xray binary on both hosts (including simplified reverse settings and certificate pin support), not only Nix evaluation. In an approved maintenance window, deploy Veles portal with `egress.via = "forward"`, then Buyan bridge; wait for **both** dynamic tags and valid independent observatory results. Only then set Veles `egress.via = "reverse"`. Restart can interrupt existing sessions. Do not perform a deployment as part of this design work.
- Through a real Veles client inbound and NixPi, make fresh TCP and UDP requests and confirm both successful response and **Buyan egress**. Select each reverse transport in turn during an approved test; a shared Buyan exit IP does not prove which one was used—inspect sanitized per-tag metrics/logs. Disconnect first one link, then both; after bounded health detection, new requests must choose the remaining link and finally fail closed, not forward or exit from Veles. Verify private/link-local/resolved-private target denial on Buyan and ordinary Buyan public clients still function. Restoring links should restore selection, not replay broken streams.
- Roll back by switching Veles to `egress.via = "forward"` (NixOS previous generation if necessary), which deliberately enables configured forward outbounds; there is **no automatic** reverse→forward fallback. Do not enable forward before verifying Buyan's corresponding existing public inbounds. Operator approval is required for all live tests, rollout, or rollback. No secrets, commits or pushes are authorized by this spec alone.

## Limits

A healthy observatory result or accepted config is not proof of correct reverse TCP/UDP delivery. Dynamic reverse registration and leastPing startup behavior vary with Xray versions; if they fail on the deployed version, do **not** cut over. A reverse connection changes which host initiates the handshake, not the path traversed by bidirectional packets. The old `randomized` forward/client fingerprint has documented reliability concerns in `docs/research/2026-09-30-veles-buyan-xray-transport-failures.md`; preserving it is scope control, not recommending it for new deployments.
