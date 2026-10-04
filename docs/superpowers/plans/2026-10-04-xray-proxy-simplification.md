# Xray Proxy Simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Veles's duplicate direct/relay inbounds and forward-only default with a four-inbound, fail-closed reverse relay over two Buyan-initiated links; flatten the machine-agnostic Xray modules and remove MTProxy/subscriptions.

**Architecture:** One explicitly enabled client, relay or server mode generates a complete Xray config using a small shared VLESS builder and existing Hysteria2 support. Veles routes via reverse RAW/xHTTP `leastPing` or manually selected classic forward candidates; Buyan keeps its public server and routes reverse traffic only through restricted public egress. The runtime bridge user is the existing host-authorized `buyan` JSON user, not a new credential.

**Tech Stack:** NixOS flake, Nix modules, Xray-core from the existing unstable overlay, Nginx SNI router, systemd `LoadCredential`, jq, bash, nixfmt.

**Spec:** `docs/superpowers/specs/2026-10-04-xray-proxy-simplification-design.md`

## Global Constraints

- Veles has **one** client-facing inbound per protocol (VLESS RAW, gRPC, xHTTP, Hysteria2); no MTProxy, relay SOCKS inbound or Veles-direct Xray proxy egress. Preserve NixPi's actual Veles relay SNIs and Buyan's public VLESS inbounds.
- In `egress.via = "reverse"`, emit **zero** Veles-initiated forward outbounds; select separate dynamic reverse RAW/xHTTP tags using `leastPing`, fall back **only** to `blocked-out`, and do not replay existing streams. In `"forward"`, use configured Veles-initiated candidates with fail-closed fallback; no automatic reverse→forward fallback.
- Preserve all Veles forward target settings in the machine config, including disabled Hysteria2, and keep both server and relay Hysteria2 capabilities. Replace old `pinSHA256` with `certificateFingerprint : nullOr str` for forward Hysteria2, mutually exclusive with `insecure = true` when enabled; validate actual binary support.
- Use the existing `buyan` user from `secrets.singBoxUsers`. Exclude it from **ordinary** Veles users on all protocols; add it as a reverse-only client to Veles RAW and xHTTP, and use its UUID for Buyan's simplified VLESS reverse outbounds. Do not add a UUID, secret-file entry, secret mode, reverse port, second Xray process, or new dependency. No hostnames or internal secret imports inside Xray role code.
- Buyan public-client traffic routes explicitly to ordinary `direct-out`; both reverse logical inbounds route explicitly to restricted `reverse-public-out`; default first outbound on Buyan/Veles is `blocked-out`. Assert private/reserved target denial on the deployed binary.
- Preserve existing SNI router, TCP/2053 redirects, observability metrics, NixPi SOCKS/HTTP/fixed-destination tunnel, existing external service config and current NixPi/forward fingerprints. No `roles.xray.enable`; exactly one mode is enabled.
- Evaluate with committed dummy data in the **isolated worktree** only; never overwrite a real ignored `secrets/secrets.json` or echo a credential. No deployment, push or commit without a separate request. Worktree: `/Users/o__ni/Code/Git/my-nix/.worktrees/refactor-xray-reverse-relay-simplification`, branch `refactor/xray-reverse-relay-simplification`.

---

## Files and interfaces

- Create `roles/network/xray/vless.nix`: pure `mkInbound`, `mkRegularOutbound`, `mkReverseOutbound` helpers. `mkInbound` accepts `{ transport, tag, port, clients, sni, shortIds, path ? "/vl-xhttp", serviceName ? "VlGrpc" }`; `mkRegularOutbound` accepts `{ tag, address, port, uuid, streamSettings, flow ? null }`; `mkReverseOutbound` accepts `{ tag, address, port, uuid, inboundTag, streamSettings, flow ? null }`. `transport` is `"raw"`, `"grpc"` or `"xhttp"`. The reverse builder uses simplified settings, never `vnext`.
- Modify `roles/network/xray/hysteria.nix`: retain Hysteria2 inbound construction for server and relay and optional forward outbound; rename `pinSHA256` to `certificateFingerprint`, render the certificate pin in `tlsSettings` when set. No transport registry needed for Hysteria2.
- Modify `roles/network/xray/client.nix`: `roles.xray.client.{enable,ingress,egress}` and **complete** NixPi client JSON; keep NixPi tunnels and backup-port balancer. Modify `machines/nixpi/default.nix` together with it.
- Modify `roles/network/xray/server.nix`: `roles.xray.server.{enable,ingress,reverseBridge}`, complete Buyan JSON with public inbounds, optional Hysteria2 server, two simplified reverse bridge outbounds and separate policy. Modify `machines/buyan/default.nix` in the integrated mode step.
- Modify `roles/network/xray/relay.nix`: `roles.xray.relay.{enable,ingress,egress}` and complete Veles JSON including optional Hysteria2 relay, reverse user exclusion, dynamic reverse tags/balancer, dormant forward settings in reverse mode. Modify `machines/veles/default.nix` together with it.
- Modify `roles/network/xray/default.nix`: mode exclusivity, selected full config, `_configTemplate` read-only eval seam, SNI entries, shared server/relay runtime credential injection and explicit JSON validation; keep no `_serverConfig`, `_relayConfig` or `_extraConfig` fragment plumbing. Modify `roles/network/xray/metrics.nix` to require server or relay and attach metrics JSON without an option-level fragment registry.
- Update `roles/network/xray/tests/reverse.sh` (existing integration/eval test): cover all three modes and adverse cases; preserve meaningful old Buyan egress, matched SNI/path and startup-command assertions while replacing expectations for the retired topology. Modify `roles/observability/dashboards/proxy-health.json` when generic reverse tags replace host-named tags.
- Delete `roles/network/xray/transports/{default.nix,lib.nix,tcp.nix,grpc.nix,xhttp.nix}`, `roles/network/xray/subscriptions.nix`, `roles/network/mtproxy.nix` after their consumers migrate. Remove Veles's telemt overlay in `flake.nix`, unused MTProxy dummy data in `secrets/secrets.dummy.json`, and current MTProxy/subscriptions inventory mentions in `README.md` and `AGENTS.md` (read the writing-for-agents skill before editing `AGENTS.md`). Do not rewrite historical research/spec documents or touch real/encrypted secret contents.
- `docs/proxy.md` is the new target-topology description; align it with final behavior if implementation reveals a discrepancy.

**Important ordering:** Do not delete the old transport registry or fragment options while another mode still consumes them. Task 3 Steps 2–5 are **one atomic integration checkpoint**, not four independently evaluable checkpoints: relay/server, coordinator and both machines must switch together. The red test from Step 1 remains expected to fail throughout this batch. Do not claim `make check` or `reverse.sh` passes, hand off a partial tree, or delete the old imports until Step 5 is complete; run both checks in Step 6 before claiming the checkpoint is evaluable. Tasks 1, 2 and 4 each have their own green checks. A review checkpoint is not authorization to commit.

### Task 1: Extract the VLESS builder without changing active hosts

**Files:** Create `roles/network/xray/vless.nix`; no existing role changes yet.

**Interfaces:** Export three pure functions `mkInbound`, `mkRegularOutbound`, `mkReverseOutbound` with the exact argument names in the Files and interfaces section. Caller constructs the transport-specific REALITY client `streamSettings`; these helpers never read machine config or secrets.

- [ ] **Step 1: Red check.** From the worktree root run this with dummy secrets; it must fail because `vless.nix` does not exist:

```bash
flake="path:$(pwd -P)"
nix eval --impure --json --expr '
let
  f = builtins.getFlake "'"$flake"'";
  vless = import ./roles/network/xray/vless.nix { lib = f.nixosConfigurations.veles.lib; };
in vless.mkReverseOutbound {
  tag = "reverse-test"; address = "127.0.0.1"; port = 443;
  uuid = "00000000-0000-4000-8000-000000000001";
  inboundTag = "reverse-test-in"; flow = null;
  streamSettings = { network = "xhttp"; security = "reality"; };
}
' | jq -e '.settings.reverse.tag == "reverse-test-in" and (.settings.vnext? == null)'
```

- [ ] **Step 2: Implement three small functions.** `mkInbound` emits `listen = "127.0.0.1"`, `protocol = "vless"`, `settings = { inherit clients; decryption = "none"; }`, REALITY target/serverNames/shortIds, `sockopt.acceptProxyProtocol = true`, and only the matching network-specific fields. The regular outbound uses `vnext`; the reverse outbound **must not**. For the latter, the crucial shape is:

```nix
mkReverseOutbound =
  { tag, address, port, uuid, inboundTag, streamSettings, flow ? null }:
  {
    protocol = "vless";
    inherit tag streamSettings;
    settings = {
      inherit address port;
      id = uuid;
      encryption = "none";
      reverse.tag = inboundTag;
    } // lib.optionalAttrs (flow != null) { inherit flow; };
  };
```

Build `mkRegularOutbound` with `settings.vnext = [ { inherit address port; users = [ ({ id = uuid; encryption = "none"; } // lib.optionalAttrs (flow != null) { inherit flow; }) ]; } ]`; keep one pure ClientHello-fragment helper here for eventual call sites. Do not change the existing builders yet.

- [ ] **Step 3: Green and failure checks.** Re-run Step 1; it must pass. Evaluate `mkInbound` with `transport = "raw"`, `"grpc"` and `"xhttp"` and assert the emitted networks are respectively `tcp`, `grpc` (ALPN `h2`, `grpcSettings.serviceName = "VlGrpc"`), and `xhttp` (`xhttpSettings.path = "/vl-xhttp"`). Assert `mkRegularOutbound.settings.vnext` exists but `mkReverseOutbound.settings.vnext` does not. Run `make check`. Keep the registry for its still-active consumers.

### Task 2: Migrate NixPi's client mode and public inputs

**Files:** Modify `roles/network/xray/client.nix`, `machines/nixpi/default.nix`; optionally extend `roles/network/xray/tests/reverse.sh` only with standalone NixPi checks that do not depend on Veles/Buyan migration.

**Interfaces:** Produce `roles.xray.client.ingress.{socks.port,http.enable,http.port,openFirewall,tunnels}` and `.egress.{server,user,backupPort,reality.{publicKey,shortId,fingerprint},vless.{raw,grpc,xhttp}}`. Reuse `vless.mkRegularOutbound`, current transport defaults (`grpc.serviceName = "VlGrpc"`, `xhttp.path = "/vl-xhttp"`), original NixPi user/target, 443 and 2053 candidates, HTTP/SOCKS/tunnel ports and existing fingerprint. The old root `roles.xray.enable` remains only until Task 3's integrated switch.

- [ ] **Step 1: Capture old and red state.** Save *sanitized* eval projections, not full user-bearing JSON: `nix eval --json "$flake#nixosConfigurations.nixpi.config.services.xray.settings" | jq '{inbounds:[.inbounds[].tag],outbounds:[.outbounds[].tag],balancers:.routing.balancers}'`. Check that evaluating `...config.roles.xray.client.egress.vless.raw.enable` fails before adding the new option schema.
- [ ] **Step 2: Implement/migrate in one checkpoint.** Replace the old `client.vlessTcp/vlessGrpc/vlessXhttp` flat options with `.egress.vless.raw/grpc/xhttp` and `client.{port,http,tunnels,openFirewall}` with `.ingress.{socks.port,http,tunnels,openFirewall}`. Keep the existing endpoint parser including bracketed IPv6 and duplicate-listener assertions. Build the complete client JSON with the new VLESS helper and the existing `leastPing`/60-second observation behavior. In `machines/nixpi/default.nix` move the single `nixpiXrayUser` and Veles address up to `.egress.user`/`.egress.server`; keep the existing SNI, backup port and 5053→1.1.1.1:853 tunnel.
- [ ] **Step 3: Verify behavior and failure.** Compare the sanitized old/new projections (same inbound types, three transports × two ports and balancer candidates). Assert NixPi never gets a Veles/Buyan reverse outbound. Test one malformed tunnel endpoint using `extendModules` and confirm the existing boundary validation fails. Run `make check`. Do not change NixPi's `randomized` fingerprint in this refactor.

### Task 3: Implement complete server and relay modes as a single integrated seam

**Files:** Modify `roles/network/xray/server.nix`, `roles/network/xray/relay.nix`, `roles/network/xray/default.nix`, `roles/network/xray/metrics.nix`, `machines/{veles,buyan}/default.nix`, `roles/network/xray/tests/reverse.sh`, `roles/observability/dashboards/proxy-health.json`.

**Interfaces:** Produce mode options and complete `_configTemplate` described in the spec. Generic tags: `blocked-out`, `reverse-raw-out`, `reverse-xhttp-out` and `hy2-relay-in` on Veles; `bridge-raw-out`, `bridge-xhttp-out`, `reverse-raw-in`, `reverse-xhttp-in` on Buyan; `reverse-public-out` for restricted freedom. Reserve `hy2-in` for Buyan's optional Hysteria2 server inbound. Veles `egress.reverse.user : nullOr attrs` defaults `null`; its presence creates both reverse-marked inbound entries even when `egress.via = "forward"`. `egress.via : enum [ "forward" "reverse" ]`; reverse mode requires a reverse user, forward mode requires a server/user and at least one enabled target. Buyan `reverseBridge.enable : bool` defaults false, with explicit `user`, `address`, REALITY public key/short ID, per-transport SNI and xHTTP path.

- [ ] **Step 1: Add failing topology tests before changing modes.** Rewrite `roles/network/xray/tests/reverse.sh` to assert the new contract; running it **must fail** against the unchanged hosts. The core check (following the script's existing `veles=$(nix eval ...)` and `buyan=$(nix eval ...)` setup) is:

```bash
printf '%s' "$veles" | jq -e '
  . as $cfg |
  ([.inbounds[].tag] | sort == ["hy2-relay-in", "vless-grpc-in", "vless-raw-in", "vless-xhttp-in"])
  and (.outbounds[0].tag == "blocked-out")
  and ([.outbounds[] | select(.tag == "direct-out" or (.tag | startswith("forward-")))] | length == 0)
  and ([.routing.balancers[] | select(.tag == "reverse-balancer" and .strategy.type == "leastPing" and .selector == ["reverse-raw-out", "reverse-xhttp-out"] and .fallbackTag == "blocked-out")] | length == 1)
  and (["vless-raw-in", "vless-grpc-in", "vless-xhttp-in", "hy2-relay-in"] as $ingress |
    all($ingress[]; . as $tag |
      ([$cfg.routing.rules[] | select((.inboundTag // []) | index($tag)) | .balancerTag] == ["reverse-balancer"])
      and ([$cfg.routing.rules[] | select(((.inboundTag // []) | index($tag)) and has("outboundTag")) | .outboundTag] == [])))
  and (all(["reverse-raw-out", "reverse-xhttp-out"][]; . as $tag | any($cfg.observatory.subjectSelector[]; . as $sel | $tag | startswith($sel))))
' >/dev/null
```

Additionally assert: only RAW/xHTTP carry the existing Buyan UUID with `reverse.tag`; no Veles relay SOCKS or duplicate `*-fwd-in` listeners; Buyan has exactly one `bridge-raw-out` (`settings.reverse.tag = "reverse-raw-in"`) and one `bridge-xhttp-out` (`settings.reverse.tag = "reverse-xhttp-in"`), both with simplified `settings` (`vnext == null`), matching SNI/path, RAW Vision flow and distinct logical reverse inbound rules to `reverse-public-out`. Preserve the existing script's restricted `finalRules`, no secret-file credential and explicit JSON `-format json` checks adapted to generic tags. Do not log UUIDs from the dummy fixture or real secrets.
- [ ] **Step 2: Build relay full JSON (atomic with Steps 3–5; do not verify standalone).** Take only `ingress.vless` and `ingress.hysteria2`: use `vless.mkInbound` for RAW/gRPC/xHTTP and Hysteria `mkRelayInbound` for UDP, preserving its `hy2-relay-in` tag for credential dispatch. RAW clients have Vision flow, gRPC/xHTTP do not. Exclude `egress.reverse.user.uuid` from **all** normal client lists, including Hysteria, then add reverse-marked RAW/xHTTP clients with distinct tags. Assert reverse user membership and uniqueness, nonempty SNI, and Hysteria TLS paths when enabled. Make reverse mode's only static outbound `{ protocol = "blackhole"; tag = "blocked-out"; }`, route all four ingress tags to a `reverse-balancer` (`leastPing`, selectors `[ "reverse-raw-out" "reverse-xhttp-out" ]`, `fallbackTag = "blocked-out"`) and observe both dynamic tags. Forward mode instead generates existing configured RAW/gRPC/xHTTP candidates, configured backup TCP port and optional Hysteria2 forward outbound behind a separate `leastPing` balancer, also falling back to `blocked-out`. No permanent `direct-out` on Veles. In the **same integration step**, rename `hysteria.relayTargetOptions.hysteria.pinSHA256` to `certificateFingerprint = mkOption { type = types.nullOr types.str; default = null; ...; }` in `hysteria.nix`, render non-null values as a single hex string in `tlsSettings.pinnedPeerCertSha256` (not the retired `pinnedPeerCertificateChainSha256` array), and reject `egress.forward.hysteria2.enable && insecure && certificateFingerprint != null`. Never enable this target without deployed-binary pin verification.
- [ ] **Step 3: Build server full JSON (same atomic batch).** Reuse `vless.mkInbound` with Buyan's existing server SNIs and normal users; retain optional Hysteria `mkServerInbound`. Generate two `mkReverseOutbound` calls for Buyan: `bridge-raw-out` with `inboundTag = "reverse-raw-in"` (Vision), and `bridge-xhttp-out` with `inboundTag = "reverse-xhttp-in"` (xHTTP path, no flow), both with Firefox fingerprint and existing optional ClientHello fragmentation. Use the existing `buyan` user explicitly passed by the machine; avoid selecting it in the module. Order outbounds `blocked-out`, `direct-out`, two bridge outbounds, `reverse-public-out`; public inbound routing must explicitly target `direct-out`, and the **only** two logical reverse inbound tags explicitly target the restricted freedom outbound with `finalRules = [ { action = "allow"; network = "tcp,udp"; ip = [ "!geoip:private" ]; } ]`. No reverse ingress may rely on first-outbound defaults.
- [ ] **Step 4: Replace coordinator fragment merging (same atomic batch).** Require at most one mode, choose its **complete** config as `roles.xray._configTemplate`, remove `_serverConfig`, `_relayConfig`, `_extraConfig` and redundant `roles.xray.enable` *after all modes have migrated*. Attach metrics JSON based on `roles.xray.metrics.enable` with no module fragment. For server/relay, retain `LoadCredential` for REALITY private key and enabled Hysteria cert/key; the jq dispatch must distinguish `hy2-relay-in` from server `hy2-in`, installing the relay credential on Veles rather than the server credential. Render mode-0600 config using jq, run `xray run -test -format json -config "$configFile"`, then `exec xray run -format json -config "$configFile"`. The JSON-sourced reverse UUID is intentionally already in the generated template; do not add reverse UUID runtime credential injection. Bind SNI entries from the active mode's enabled ingress values; Hysteria opens only its configured UDP port. Change metrics' server-only assertion to accept either server or relay; keep collector behavior.
- [ ] **Step 5: Switch host declarations together (complete the atomic batch before checking).** Set Veles's sole role to `roles.xray.relay` with the spec's `ingress` and `egress` tree; `reverseUser = selectProxyUser "buyan" users` (where `users` is the existing host-filtered list) and forward `relayUser = selectProxyUser hostname secrets.singBoxUsers`. Set Buyan's `roles.xray.server.ingress` with unchanged public SNIs, and `.reverseBridge.user = selectProxyUser "buyan" secrets.singBoxUsers`, targeting Veles's relay RAW/xHTTP SNIs, not its retired direct SNIs. Pass both hosts' `reality.shortIds` explicitly from secrets, not an internal module import. Keep NixPi's current Veles SNIs. Update dashboard tag queries/legends from `reverse-buyan-out` to `reverse-raw-out` and `reverse-xhttp-out`, including `bridge-raw-out`, `bridge-xhttp-out` and `reverse-public-out` in the bridge-side and egress rates.
- [ ] **Step 6: Green/adverse checks.** Run `make check` and `bash roles/network/xray/tests/reverse.sh "path:$(pwd -P)"`. Extend the test with `extendModules` variations: `egress.via = "forward"` yields the configured primary/backup forward candidates and never a Veles `direct-out`; selecting reverse with no reverse user fails; duplicating the reverse user's UUID in ordinary clients fails; setting a required RAW or xHTTP ingress SNI to `""` fails; both roles enabled on one host fails; bridge serverName/path mismatch is caught by cross-host eval assertions; enabling Hysteria2 forward with both pin and insecure fails. Do not log UUID/password data from the assertions. `git diff --check` at this checkpoint.

### Task 4: Remove unused paths and reconcile documentation

**Files:** Delete `roles/network/xray/transports/{default.nix,lib.nix,tcp.nix,grpc.nix,xhttp.nix}`, `roles/network/xray/subscriptions.nix`, `roles/network/mtproxy.nix`; modify `flake.nix`, `secrets/secrets.dummy.json`, `README.md`, `AGENTS.md`, `machines/veles/default.nix`, `roles/network/xray/tests/reverse.sh`, `docs/proxy.md` only if target text needs correction.

**Interfaces:** No role imports the registry or subscription module; no host enables MTProxy/telemt or Xray relay SOCKS. Keep unrelated `nixpkgs-unstable` use on Veles (Xray overlay) and other flake outputs unchanged. Do not edit encrypted/ignored secrets.

- [ ] **Step 1: Make removal checks fail against the current files.** Search `rg -n 'mtproxy|telemt|subscriptions|transports/|socks-relay-in|relay\.socks|roles\.xray\.enable' roles/network/xray roles/network/mtproxy.nix machines flake.nix README.md AGENTS.md`. Add assertions to the revised `reverse.sh` that Veles has no `socks-relay-in`, no extra direct VLESS listeners, no MTProxy service and no MTProxy SNI entry; before removal they fail.
- [ ] **Step 2: Delete after verifying zero active imports.** Delete the unused registry files and subscription module, and the MTProxy role. Remove `roles.mtproxy` and `relay.socks` from Veles, Veles-only telemt overlay from `flake.nix`, MTProxy dummy JSON key and outdated current-inventory references from `README.md`/`AGENTS.md`. Follow the writing-for-agents skill before editing `AGENTS.md`; preserve historical docs as historical. Keep SNI-router TCP/443, REDIRECT TCP/2053 and Hysteria UDP/443. Confirm `secrets/unlocked/spec.txt` needs no reverse UUID entry. Do not attempt to delete MTProxy from a real or encrypted secrets file; ask the operator to clean that up separately if desired.
- [ ] **Step 3: Verify.** Run `nixfmt` on changed Nix files, `make check`, `bash roles/network/xray/tests/reverse.sh "path:$(pwd -P)"`, and `git diff --check`. Confirm `git status --short` lists only intended paths and no ignored credentials. Check `docs/proxy.md` matches actual generated topology and staged activation. No `nixos-rebuild switch`, commit or push.

## Deployed-binary and rollout gate — operator approval required

**Do not execute as part of this plan-writing or implementation-only request.** The machine configs in Tasks 3–4 describe the target; do not switch Veles straight to reverse in production before the two links pass staging. With separate explicit deployment approval: identify the actual installed Xray version on each host; securely render and run the same binary's `run -test -format json` against both configs; establish the Veles portal while `egress.via = "forward"`, then Buyan's two bridge links; verify each dynamic tag and its independent observatory result; make controlled TCP and UDP requests through both links and verify Buyan public egress and restricted policy. Only then switch Veles to `"reverse"`. Disconnect one, then both links and verify remaining-route selection, blackhole (not forward/direct) on total failure, and recovery on new requests. Test denial of loopback, RFC1918, link-local, other reserved and privately resolved domain targets. A successful Nix eval, syntactic Xray check or common Buyan exit IP alone does not prove these behaviors. Roll back manually to `"forward"`/a known-good NixOS generation if any gate fails. Sanitize logs and do not publish credentials or packet captures.

## Plan self-review checklist

- Spec coverage: client, relay, server, shared VLESS/Hysteria2, MTProxy/subscriptions deletion, metrics, SNI/ports, JSON secrets and pin semantics each have a named task and check; runtime-only behavior is explicitly gated.
- Interface consistency: machine mode options and `egress.via`, `egress.reverse.user`, `egress.forward.hysteria2.certificateFingerprint`, `reverseBridge.user` are named identically in this plan and the spec.
- No changes to real/encrypted secrets, no extra credentials, no implicit Veles direct route, no automatic forward fallback, and no commit without instruction.
