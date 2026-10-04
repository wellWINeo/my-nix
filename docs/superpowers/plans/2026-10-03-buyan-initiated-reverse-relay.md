# Buyan-Initiated Reverse Relay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route Veles relay traffic over a Buyan-initiated xHTTP+REALITY reverse link, with Buyan as TCP/UDP internet egress and `relay-grpc-out` as a best-effort fallback for new requests.

**Architecture:** One reverse-only UUID authenticates Buyan to Veles's existing server xHTTP inbound. Veles selects the dynamically registered reverse outbound for relay inbounds only; Buyan routes the matching reverse inbound to a restricted public-internet `freedom` outbound. The existing relay outbounds, balancer, public listeners and direct-server routes remain intact.

**Tech Stack:** Nix flakes/NixOS modules, Xray-core (deployed version must be validated), systemd `LoadCredential`, `jq`, bash, existing Nix evaluation and `make check`.

**Spec:** `docs/superpowers/specs/2026-10-03-buyan-initiated-reverse-relay-design.md`

## Global Constraints

- Buyan initiates the inter-server link with **xHTTP+REALITY over TCP/443** to Veles's existing server xHTTP inbound (server SNI `vk.ru`, path `/vl-xhttp`); the reverse outbound uses a fixed `firefox` fingerprint and the existing optional ClientHello fragmentation setting.
- Only Veles's **relay inbounds** change routing; its direct server inbounds keep `direct-out`. The fallback is **one named outbound**, `relay-grpc-out`, not the `relay-balancer` and not Veles direct egress.
- Buyan allows reverse-proxied **TCP and UDP to public destinations only**, denying private and non-public targets; reverse ingress must never inherit Buyan's ordinary unrestricted `direct-out` implicitly.
- One dedicated reverse UUID must be provisioned on **both** hosts as an encrypted file, installed `0400 root:root`, loaded at runtime, and absent from Nix store templates, `singBoxUsers`, and subscriptions. No production credentials appear in tests, commands, logs, or this plan.
- Do not change existing Veles → Buyan candidates, fingerprint, ports, NixPi, subscriptions, DNS or public SNI routing. No new dependencies or services. The unstable Xray package may change; test the actual binary on both hosts.
- Deploy/restart, secret provisioning and any commit require separate explicit user authorization. Never overwrite an existing ignored `secrets/secrets.json` with `make setup-dummy-secrets`. Stage files explicitly if a commit is subsequently requested; do not commit on `main`/`master`.

---

## Files and interfaces

- `roles/network/xray/server.nix`: add the portal-only reverse client to the single `vless-xhttp-in` client list; other transport builders and ordinary users unchanged.
- `roles/network/xray/default.nix`: define `roles.xray.reverse.portal.enable`, `.bridge.enable`, `.uuidFile`, `.bridge.{address,serverName,path,publicKey,shortId}`; assemble Buyan's simplified outbound/egress rule; add a read-only internal `_configTemplate` for evaluating the actual assembled config; inject the UUID via runtime credentials.
- `roles/network/xray/relay.nix`: define `roles.xray.relay.useReverse`, swap only relay rules to `reverse-first-balancer`, and retain the old `relay-balancer`.
- `machines/veles/default.nix`, `machines/buyan/default.nix`: enable the portal/bridge respectively; leave Veles `relay.useReverse = false` until the cutover deployment.
- `roles/network/xray/tests/reverse.sh`: persistent evaluation assertions of portal isolation, Buyan egress and reverse-first/fallback routing. Run with the existing `nix`/`jq`/bash toolchain, not a new test runner.
- `secrets/unlocked/spec.txt`: declare the same reverse UUID filename for both hosts; **do not create or commit the secret contents** as an agent task.

The exact public Nix option contract is `roles.xray.reverse.portal.enable : bool`, `roles.xray.reverse.bridge.enable : bool`, `roles.xray.reverse.uuidFile : path`, `roles.xray.reverse.bridge.address/serverName/path/publicKey/shortId : str`, and `roles.xray.relay.useReverse : bool` (all enable flags default `false`). Use these names consistently; the bridge settings are required only if bridge mode is enabled. Internal `_configTemplate : attrs` mirrors the exact JSON given to `pkgs.writeText` and is not a new user-facing configuration surface. Tags are `reverse-buyan-out` (dynamic Veles outbound), `reverse-veles-in` (dynamic Buyan inbound), `reverse-veles-client` (static Buyan outbound), `reverse-public-out` (Buyan freedom) and `reverse-first-balancer` (Veles balancer).

## Safe validation source tree

Avoid overwriting the working tree's ignored, possibly real `secrets/secrets.json`. For local tests and `make check`, build a temporary tree from tracked files **plus the new test file** and install dummy JSON only there:

```bash
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git ls-files -z | rsync -a --from0 --files-from=- ./ "$tmp/"
install -D -m 0644 roles/network/xray/tests/reverse.sh "$tmp/roles/network/xray/tests/reverse.sh"
cp secrets/secrets.dummy.json "$tmp/secrets/secrets.json"
tmp=$(cd "$tmp" && pwd -P) # macOS /var is a symlink; Nix path: needs the canonical path
flake="path:$tmp"
```

Run this setup in the same shell as subsequent test commands. `rsync` copies working-tree content of tracked files, not their HEAD versions; it excludes ignored decrypted secrets. At each verification gate recreate the tree so changes to tracked Nix files are reflected. The plan and research docs are intentionally not required for Nix evaluation.

### Task 1: Portal-only reverse client and credential injection

**Files:** Modify `roles/network/xray/server.nix`, `roles/network/xray/default.nix`, `machines/veles/default.nix`, `secrets/unlocked/spec.txt`; test the assembled portal template.

**Interfaces:** Produces `roles.xray.reverse.portal.enable`, `.uuidFile`, Veles's `reverse-buyan-out` dynamic tag, and `roles.xray._configTemplate`. Consumes Veles's existing `server.vlessXhttp.enable`, SNI router and REALITY private-key credential. It does not change any ordinary user or relay route.

- [ ] **Step 1: Write/run a failing portal check.** In the temporary source tree, this assertion must fail before implementation (unknown option or zero reverse clients). The module override makes it runnable *before* Veles is opted in:

```bash
nix eval --impure --json --expr '
let f = builtins.getFlake "'"$flake"'";
in (f.nixosConfigurations.veles.extendModules {
  modules = [ { roles.xray.reverse.portal.enable = true; } ];
}).config.roles.xray._serverConfig.inbounds
' | jq -e '[.[] | select(.tag == "vless-xhttp-in") | .settings.clients[] | select(.reverse.tag? == "reverse-buyan-out")] | length == 1'
```

- [ ] **Step 2: Add the portal option and append exactly one reverse client.** Under `roles.xray.reverse`, add `portal.enable = mkEnableOption "dedicated Buyan-initiated reverse portal";`, `bridge.enable = mkEnableOption "Buyan reverse bridge";`, and `uuidFile = mkOption { type = types.path; default = "/etc/nixos/secrets/xray-reverse-uuid"; description = "Installed reverse UUID credential file"; };`. Assert portal and bridge are not both enabled, either requires `roles.xray.server.enable`, and portal requires `roles.xray.server.vlessXhttp.enable`. In `server.nix` add only to the result for `t.name == "vlessXhttp"`:

```nix
let
  inbound = t.mkServerInbound {
    cfg = cfg.${t.name};
    inherit clients shortIds;
  };
in
if t.name == "vlessXhttp" && config.roles.xray.reverse.portal.enable then
  lib.recursiveUpdate inbound {
    settings.clients = inbound.settings.clients ++ [
      {
        id = "00000000-0000-4000-8000-000000000001";
        reverse.tag = "reverse-buyan-out";
      }
    ];
  }
else
  inbound
```

The displayed block replaces the body of `map (t: t.mkServerInbound { cfg = cfg.${t.name}; inherit clients shortIds; }) enabledTransports`; use its surrounding `let`/`in`, not a second map. This placeholder is only a valid JSON-template UUID: the running service **must** replace it from the credential or fail startup. Do not add it to `cfg.users`.

- [ ] **Step 3: Extend the current systemd service, not `services.xray.settings`.** Add `"reverse-uuid:${cfg.reverse.uuidFile}"` to `LoadCredential` only when portal or bridge is enabled. Before rendering, read the credential, strip one trailing newline, reject anything not matching the UUID shape `^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`, and avoid tracing/printing it. Add `--arg reverseId "''${reverseId:-}"` to the existing `jq` call; compose these two assignments **after** the current REALITY/Hysteria inbound filter (each is a no-op when its tagged object does not exist):

```jq
| (.inbounds[] | select(.tag == "vless-xhttp-in") | .settings.clients[] |
   select(.reverse.tag? == "reverse-buyan-out") | .id) = $reverseId
| (.outbounds[] | select(.tag == "reverse-veles-client") | .settings.id) = $reverseId
```

Use `set -euo pipefail`, `umask 077` and `configFile="$(mktemp)"` rather than writing to the fixed `/tmp/xray.json` (which may already have permissive permissions). Write `jq` output to `"$configFile"`, run `xray run -test -config "$configFile"` and only then `exec xray -config "$configFile"`; `mktemp` creates the rendered config mode `0600` under the service's existing `PrivateTmp`. The validator is an activation guard, not a proof of reverse-link behavior. Bind an internal `_configTemplate` option to the **same** `xrayConfigTemplate` expression passed to `pkgs.writeText`, so eval tests inspect the actual assembled JSON. Retain existing Hysteria credential handling. The reverse credential read should be conditional, since Buyan/Veles are the only opted-in hosts and default-off Xray hosts must still start without it.

- [ ] **Step 4: Opt Veles into portal admission and finish the green check.** Add `reverse.portal.enable = true;` to the existing Veles `roles.xray` block without changing any `relay` routes. Add both lines to `secrets/unlocked/spec.txt`:

```text
veles:xray-reverse-uuid:0400:root:root
buyan:xray-reverse-uuid:0400:root:root
```

Re-run Step 1 and the same query without the override: both now return `true`. With `jq`, assert `vless-tcp-in` and `vless-grpc-in` have zero reverse clients and the new user is absent from `roles.xray.server.users`. Inspect the `LoadCredential` entry for Veles, but never read or create the real UUID. The reverse UUID placeholder must only be present in the rendered template until runtime injection.

### Task 2: Buyan bridge, restricted public egress, and runtime config

**Files:** Modify `roles/network/xray/default.nix`, `machines/buyan/default.nix`.

**Interfaces:** Produces simplified VLESS outbound `reverse-veles-client` with `settings.reverse.tag = "reverse-veles-in"` and `reverse-public-out : freedom`; consumes Task 1's credential-injection contract. No `vnext` under this outbound.

- [ ] **Step 1: Red check.** With dummy secrets, check that Buyan does *not yet* have a bridge outbound:

```bash
nix eval --json "$flake#nixosConfigurations.buyan.config.roles.xray._configTemplate" |
  jq -e '[.outbounds[] | select(.tag == "reverse-veles-client")] | length == 1'
```

- [ ] **Step 2: Define required bridge target options and compose the two outbounds.** Add `bridge.address`, `.serverName`, `.publicKey` and `.shortId` as required `mkOption { type = types.str; description = "Buyan reverse-link target setting"; }` entries (give each an accurate per-field description); add `bridge.path = mkOption { type = types.str; default = "/vl-xhttp"; description = "Veles server xHTTP path"; };`. Assert nonempty values when bridge is enabled. Build `reverse-veles-client` with this **simplified** settings object, not `mkVnextOutbound`:

```nix
{
  tag = "reverse-veles-client";
  protocol = "vless";
  settings = {
    address = cfg.reverse.bridge.address;
    port = 443;
    id = "00000000-0000-4000-8000-000000000001";
    encryption = "none";
    reverse.tag = "reverse-veles-in";
  };
  streamSettings = {
    network = "xhttp";
    security = "reality";
    realitySettings = {
      publicKey = cfg.reverse.bridge.publicKey;
      shortId = cfg.reverse.bridge.shortId;
      serverName = cfg.reverse.bridge.serverName;
      fingerprint = "firefox";
    };
    xhttpSettings.path = cfg.reverse.bridge.path;
  };
}
```

If `cfg.fragmentClientHello` is true, wrap **only this outbound** with `transportHelpers.withClientHelloFragmentation` from `transports/lib.nix`; leave existing relay outbounds unchanged. Append it *after* Buyan's existing first `direct-out`. Append a separate `{ protocol = "freedom"; tag = "reverse-public-out"; settings.finalRules = [ { action = "allow"; network = "tcp,udp"; ip = [ "!geoip:private" ]; } ]; }`. Append exactly one routing rule `{ type = "field"; inboundTag = [ "reverse-veles-in" ]; outboundTag = "reverse-public-out"; }` after the current server/relay rules. Do not use `_extraConfig` to replace arrays.

- [ ] **Step 3: Opt Buyan into bridge mode only.** In `machines/buyan/default.nix`, set `reverse.bridge = { enable = true; address = secrets.ip.veles.address; serverName = "vk.ru"; path = "/vl-xhttp"; publicKey = secrets.xray.reality.publicKey; shortId = builtins.head secrets.xray.reality.shortIds; };`. The shared `reverse.uuidFile` default is the installed runtime filename. Do not enable subscriptions or new public listeners. Confirm `secrets/secrets.dummy.json` already has `ip.veles.address` before editing it; otherwise add only a fake address to the dummy fixture.

- [ ] **Step 4: Green and adverse policy checks.** Re-run Step 1; assert with `jq` that `settings.vnext` is absent, the SNI/path/Firefox settings match Veles, Buyan's first outbound is `direct-out`, the reverse inbound's only explicit route targets `reverse-public-out`, and its only `finalRules` entry permits `tcp,udp` with `!geoip:private`. On the exact Xray binary, a rendered private-address request (loopback and RFC1918 plus a domain resolving privately) must fail; an allowed public TCP request must succeed. The runtime negative tests are deployment gates, **not** claims made by Nix evaluation.

### Task 3: Veles reverse-first failover, with persistent evaluation checks

**Files:** Modify `roles/network/xray/relay.nix`, `roles/network/xray/default.nix`; create `roles/network/xray/tests/reverse.sh`.

**Interfaces:** Consumes Task 1's `reverse-buyan-out` and Task 2's Buyan bridge. Produces `roles.xray.relay.useReverse : bool`, `reverse-first-balancer` (selector `reverse-buyan-out`, fallback `relay-grpc-out`). Leaves `relay-balancer` available for rollback.

- [ ] **Step 1: Add a failing routing assertion.** Evaluate Veles with a NixOS override enabling `roles.xray.relay.useReverse = true`, then check `reverse-first-balancer` has the selector/fallback and SOCKS points to it. Before implementation the option or balancer is missing:

```bash
nix eval --impure --json --expr '
let f = builtins.getFlake "'"$flake"'";
in (f.nixosConfigurations.veles.extendModules {
  modules = [ { roles.xray.relay.useReverse = true; } ];
}).config.roles.xray._relayConfig.routing
' | jq -e '
  ([.balancers[] | select(.tag == "reverse-first-balancer" and .selector == ["reverse-buyan-out"] and .fallbackTag == "relay-grpc-out")] | length == 1)
  and ([.rules[] | select((.inboundTag // []) | index("socks-relay-in")) | .balancerTag] == ["reverse-first-balancer"])
'
```

- [ ] **Step 2: Add the opt-in switch and validation.** Define `useReverse = mkEnableOption "reverse-first routing for relay inbounds";` in `roles.xray.relay`. Change **only** the existing two relay rules (`socks-relay-in` and all enabled forwarded VLESS/Hysteria inbound tags) so `balancerTag = if cfg.useReverse then "reverse-first-balancer" else "relay-balancer";`. Append, only when enabled:

```nix
{
  tag = "reverse-first-balancer";
  selector = [ "reverse-buyan-out" ];
  fallbackTag = "relay-grpc-out";
  strategy.type = "roundRobin";
}
```

Assert `!cfg.useReverse || (config.roles.xray.reverse.portal.enable && cfg.target.vlessGrpc.enable)`; retain `relay-balancer` and its selectors/observatory. Extend the existing coordinator `observatory.subjectSelector = [ "relay-" ]` with `++ lib.optional cfg.reverse.portal.enable "reverse-buyan-out"`. Xray round-robin with `fallbackTag` uses observatory to exclude dead candidates; it assumes unobserved ones alive, so runtime loss/recovery tests are mandatory. **Do not** add reverse to `relay-balancer`, and never route direct-server inbound tags to the new balancer.

- [ ] **Step 3: Persist focused structural tests.** Create `roles/network/xray/tests/reverse.sh` as a bash script taking one argument, the `path:$tmp` flake reference from the safe-tree setup, and using `nix eval --json` + `jq -e`. It should evaluate the *actual* `config.roles.xray._configTemplate` for both hosts. Include these checks with concrete jq predicates (and fail the script on any failed predicate):

```bash
#!/usr/bin/env bash
set -euo pipefail
flake="${1:?pass path:source-tree}"
veles=$(nix eval --json "$flake#nixosConfigurations.veles.config.roles.xray._configTemplate")
buyan=$(nix eval --json "$flake#nixosConfigurations.buyan.config.roles.xray._configTemplate")
printf '%s' "$veles" | jq -e '
  . as $cfg |
  ([.inbounds[] | select(.tag == "vless-xhttp-in") | .settings.clients[] | select(.reverse.tag? == "reverse-buyan-out")] | length == 1)
  and ([.inbounds[] | select(.tag != "vless-xhttp-in") | .settings.clients[]? | select(.reverse? != null)] | length == 0)
  and (.outbounds[0].tag == "direct-out")
  and (["vless-tcp-in", "vless-grpc-in", "vless-xhttp-in"] as $tags |
       all($tags[]; . as $tag | [$cfg.routing.rules[] | select((.inboundTag // []) | index($tag)) | .outboundTag] == ["direct-out"]))
' >/dev/null
printf '%s' "$buyan" | jq -e '
  ([.outbounds[] | select(.tag == "reverse-veles-client") | select(.settings.vnext? == null and .settings.reverse.tag == "reverse-veles-in" and .streamSettings.network == "xhttp" and .streamSettings.realitySettings.fingerprint == "firefox")] | length == 1)
  and ([.outbounds[] | select(.tag == "reverse-public-out") | .settings.finalRules] == [[{"action":"allow","network":"tcp,udp","ip":["!geoip:private"]}]])
  and ([.routing.rules[] | select((.inboundTag // []) | index("reverse-veles-in")) | .outboundTag] == ["reverse-public-out"])
  and (.outbounds[0].tag == "direct-out")
' >/dev/null
```

Task 4 adds the cutover-override assertions so this test still passes while the normal Veles configuration keeps its original relay routing. This script tests configuration boundaries, **not** live forwarding.

- [ ] **Step 4: Run the structural script and both negative checks.** In the refreshed safe tree: `bash roles/network/xray/tests/reverse.sh "$flake"`. Expected: exit 0; if the portal reverse user is injected into other server inbounds, or Buyan permits private targets, the test exits nonzero. Force portal xHTTP off or relay gRPC off in separate `extendModules` evaluations and require the corresponding assertion to be false. Task 4 supplies the exact cutover-override test form.

### Task 4: Complete cutover-mode tests and validate the staged config

**Files:** Modify `roles/network/xray/tests/reverse.sh` (test-only); format the Nix files changed in Tasks 1–3.

**Interfaces:** Validates both `relay.useReverse = false` (staging) and `true` (cutover) without switching the tracked Veles host configuration. The operator supplies the real UUID only during Task 5.

- [ ] **Step 1: Red check for the missing cutover-mode assertion.** With the Task 3 script in place, this command should initially return `false` because the script only checks the default/staging Veles config:

```bash
rg -q 'reverse-first-balancer.*fallbackTag|fallbackTag.*reverse-first-balancer' roles/network/xray/tests/reverse.sh
```

- [ ] **Step 2: Add cutover and failure-mode checks to `reverse.sh`.** Evaluate a temporary module override rather than setting `useReverse` in `machines/veles/default.nix`; append the following after the existing `veles`/`buyan` assertions:

```bash
cutover=$(nix eval --impure --json --expr '
let f = builtins.getFlake "'"$flake"'";
in (f.nixosConfigurations.veles.extendModules {
  modules = [ { roles.xray.relay.useReverse = true; } ];
}).config.roles.xray._configTemplate
')
printf '%s' "$cutover" | jq -e '
  . as $cfg |
  ([.routing.balancers[] | select(.tag == "reverse-first-balancer" and .selector == ["reverse-buyan-out"] and .fallbackTag == "relay-grpc-out")] | length == 1)
  and ([.routing.balancers[] | select(.tag == "relay-balancer")] | length == 1)
  and (.observatory.subjectSelector == ["relay-", "reverse-buyan-out"])
  and (["socks-relay-in", "vless-tcp-fwd-in", "vless-grpcFwd-in", "vless-xhttp-fwd-in", "hy2-relay-in"] as $tags |
       all($tags[]; . as $tag | [$cfg.routing.rules[] | select((.inboundTag // []) | index($tag)) | .balancerTag] == ["reverse-first-balancer"]))
' >/dev/null
printf '%s' "$veles" | jq -e '
  ([.routing.balancers[] | select(.tag == "reverse-first-balancer")] | length == 0)
  and ([.routing.rules[] | select((.inboundTag // []) | index("socks-relay-in")) | .balancerTag] == ["relay-balancer"])
' >/dev/null
nix eval --impure --json --expr '
let f = builtins.getFlake "'"$flake"'"; lib = f.inputs.nixpkgs.lib;
in (f.nixosConfigurations.veles.extendModules {
  modules = [ {
    roles.xray.relay.useReverse = true;
    roles.xray.relay.target.vlessGrpc.enable = lib.mkForce false;
  } ];
}).config.assertions
' | jq -e 'any(.[]; .assertion == false and (.message | contains("useReverse")))' >/dev/null
```

Add this second negative check; in Task 1 and Task 3 give the prerequisite assertions messages containing `reverse.portal` and `useReverse` respectively, so both checks are stable:

```bash
nix eval --impure --json --expr '
let f = builtins.getFlake "'"$flake"'"; lib = f.inputs.nixpkgs.lib;
in (f.nixosConfigurations.veles.extendModules {
  modules = [ { roles.xray.server.vlessXhttp.enable = lib.mkForce false; } ];
}).config.assertions
' | jq -e 'any(.[]; .assertion == false and (.message | contains("reverse.portal")))' >/dev/null
```

These tests must not contain or evaluate a real UUID.

- [ ] **Step 3: Green and full repo checks.** Recreate the safe validation tree to pick up all tracked Nix edits plus the new test script. Run:

```bash
nixfmt roles/network/xray/default.nix roles/network/xray/server.nix roles/network/xray/relay.nix machines/veles/default.nix machines/buyan/default.nix
bash roles/network/xray/tests/reverse.sh "$flake"
(cd "$tmp" && make check)
```

The test must exit 0 and `make check` must pass before considering the staged config ready for host-side validation. Rerun the safe-tree setup after formatting if it copied pre-format Nix files. If a commit is later requested, run `nixfmt .` as this repo requires. Check that both host services declare `LoadCredential` for `reverse-uuid` and the templates contain only the placeholder UUID. Flake evaluation is not proof of runtime reverse forwarding or failover.

### Task 5: Real-host validation, controlled cutover and rollback (operator-approved only)

**Files:** Modify `machines/veles/default.nix` (set `roles.xray.relay.useReverse = true` **only** for the approved cutover); no unrequested production writes by the planning agent.

**Interfaces:** Consumes staged admission, installed shared UUID, observed dynamic reverse outbound, and Task 4's passing structural suite. Produces measured reverse-first TCP/UDP egress and fallback behavior or a restored `relay-balancer` route. This task is a deployment procedure, not a command to deploy now.

- [ ] **Step 1: Confirm the running binaries/configs.** During a maintenance window, check `xray version` on both hosts. With the installed credentials, use the Task 1 startup-rendering filter in a restricted staging context (`umask 077`, temporary config under `/run`, cleanup after validation), and run `xray run -test -config /run/xray-reverse-check.json` on each securely rendered config before switching the service. Task 1 also runs this validator in the Xray start script before `exec xray -config "$configFile"`, so every activation fails closed on invalid config. Never print the JSON or UUID. Refuse rollout if Xray rejects simplified VLESS reverse, xHTTP+REALITY, `finalRules` or the routing rules; `-test` alone does not prove Xray understood every field or that forwarding works.
- [ ] **Step 2: Stage server admission first.** With explicit deployment approval, install the shared encrypted-file secret on both hosts (verify file permissions without displaying contents), deploy Veles with only portal admission and `useReverse = false`; verify its existing relay still passes an application-level request via gRPC. Then deploy Buyan with its bridge enabled; verify the Buyan → Veles reverse connection appears and recovers from one disconnect. Before the Buyan switch, provision the geoip asset (`geoip.dat`, e.g. via `XRAY_LOCATION_ASSET` or the asset package) — `reverse-public-out`'s `!geoip:private` needs it, a passing `run -test` does not prove it is loadable, and if the reverse path fails live, check for geoip load errors first. A link-up event alone is not acceptance. If either Xray restart disrupts existing gRPC, restore that host's previous NixOS generation and pause.
- [ ] **Step 3: Cut over only relay routing.** Enable `roles.xray.relay.useReverse = true` on Veles and deploy its NixOS generation with approval. Send multiple *fresh* HTTPS requests through `127.0.0.1:1080` on Veles and an existing authenticated client-facing relay inbound (for example, a configured NixPi proxy client); verify HTTP success, Buyan's public exit IP, and increments/log evidence on `reverse-buyan-out`/Buyan `reverse-public-out`. A Buyan IP alone is not proof because gRPC fallback shares that exit. Confirm Veles's direct-server clients retain Veles egress.
- [ ] **Step 4: Validate UDP and containment.** From an existing relay client capable of proxied UDP, send a bounded DNS or QUIC request to a public endpoint; require a response and Buyan-side UDP egress evidence. Probe loopback, RFC1918, link-local, and a DNS name resolving to a private address through the reverse route; none may succeed. Check other reserved ranges relevant to Buyan, and add explicit `finalRules` denies if `geoip:private` does not exclude them. Stop if public UDP cannot traverse xHTTP reverse without silently routing through another path.
- [ ] **Step 5: Force loss/recovery and record limits.** In an approved short test temporarily block **only Buyan → Veles TCP/443** with a scoped, reversible firewall rule and an explicit removal step; avoid stopping Buyan's shared Xray service because it handles ordinary users too. Confirm the rule affects the established reverse connection, then wait for bounded health detection and issue *new* TCP and UDP relay requests. Verify both succeed via `relay-grpc-out` and still exit Buyan; record first failure, time to fallback, and any dropped in-flight streams. Restart Buyan and verify renewed reverse-path selection using tag evidence plus requests. If selection remains stale, routes through Veles `direct-out`, or UDP/TCP fails, immediately roll Veles back to the generation with `useReverse = false` and confirm the original `relay-balancer` works. Disable the bridge separately if needed. Do not treat observatory `alive=true` alone as an acceptance result.

## Review checklist and handoff

- [ ] Each spec section is represented: xHTTP ingress and dedicated UUID (Tasks 1–2), restricted TCP/UDP public egress (Task 2), relay-only routing and explicit gRPC fallback (Task 3), staged evaluation/negative checks (Task 4), deployed-version TCP/UDP/deny/failure/recovery tests (Task 5).
- [ ] No plaintext secret, implicit direct fallback, new public listener, NixPi change, subscription change or unrelated package update enters the implementation diff.
- [ ] Any candidate Xray issue is proven against the exact installed version, not inferred from flake evaluation or upstream examples.
- [ ] No commit, deployment, secret creation or service restart without a separate user request. The next executor should implement Tasks 1–4 first, run checks, then request operator approval before Task 5.
