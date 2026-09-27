# Xray Dual-Port Failover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans or superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Select Xray from unstable only on Buyan, Veles, and NixPi; add TCP/2053 as a firewall redirect to the existing TCP/443 listener on Buyan and Veles; and let Veles and NixPi balance across both port candidates.

**Architecture:** The existing Nginx stream service and Xray inbounds remain unchanged. The host firewall redirects incoming TCP/2053 to local TCP/443. Veles and NixPi each receive one backup VLESS outbound per enabled transport, and their existing `leastPing` balancers and observatories select among the 443/2053 routes.

**Tech Stack:** Nix flakes, NixOS modules/firewall (`iptables` REDIRECT), Xray-core, Nginx stream.

**Spec:** `docs/superpowers/specs/2026-09-27-xray-dual-port-failover-design.md`

## Global Constraints

- Buyan, Veles, and NixPi use `xray` from `nixpkgs-unstable`; every other package on those systems remains from stable `nixpkgs`.
- TCP/2053 is redirected by the host firewall to the existing local TCP/443 SNI-router listener on both Buyan and Veles.
- Keep the single existing Nginx stream service and its listener on TCP/443. Do not add an Nginx listener on TCP/2053 or a second Nginx instance.
- Do not add duplicate Xray server inbounds. Both public ports reach the existing SNI map and existing Xray inbound set after the redirect.
- Leave the subscription generator unchanged. Generated links continue to use TCP/443; TCP/2053 does not appear in subscriptions.
- Keep the redirect TCP-only. Veles's Hysteria2 UDP/443 listener is unchanged.
- Do not commit or deploy without a separate user request.

## Assumption to Confirm

The implementation plan uses an IPv4 `iptables` redirect, matching Buyan's explicit IPv4 interface configuration and Veles's disabled IPv6 configuration. Confirm before implementation if an IPv6-facing backup endpoint is also required.

---

## Files and Responsibilities

- `flake.nix` — define one overlay that substitutes only `pkgs.xray` from the unstable input, and apply it only to the three Xray hosts.
- `roles/network/sni-router.nix` — add an opt-in list of TCP ports redirected to the existing SNI-router port; install and remove the firewall NAT rules with the firewall lifecycle.
- `machines/buyan/default.nix`, `machines/veles/default.nix` — enable the TCP/2053 redirect.
- `roles/network/xray/transports/{tcp,grpc,xhttp}.nix` — let outbound builders accept an explicit port and unique tag while preserving their current defaults. Leave each subscription URI builder unchanged.
- `roles/network/xray/relay.nix` — add an optional target backup port, construct paired VLESS outbounds, and include both tags in `relay-balancer`.
- `machines/veles/default.nix` — set the relay target backup port to 2053.
- `roles/network/xray/client.nix` — add an optional client backup port, construct paired VLESS outbounds, and include both tags in `proxy-balancer`.
- `machines/nixpi/default.nix` — set the client backup port to 2053.

No server inbound builders, Nginx stream maps, DNS records, or subscription modules need changes.

## Validation Environment

Do not overwrite the working copy's ignored `secrets/secrets.json`. Build a temporary source tree from tracked files and supply the committed dummy secrets there:

```bash
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git ls-files -z | rsync -a --from0 --files-from=- ./ "$tmp/"
cp secrets/secrets.dummy.json "$tmp/secrets/secrets.json"
tmp=$(cd "$tmp" && pwd -P)
flake="path:$tmp"
```

Use the resulting `$flake` for the evaluation and `nix flake check` commands in these tasks. This copies tracked files, including current working-tree edits, but not ignored decrypted secrets.

## Task 1: Select unstable Xray only on the three Xray hosts

**Files:**
- Modify: `flake.nix`

- [ ] **Step 1: Add the package-source check before changing the overlay**

Run an impure Nix expression that compares each host's selected Xray derivation against both input package sets. For `buyan` and `veles`, use `x86_64-linux`; for `nixpi`, use `aarch64-linux`.

```bash
nix eval --impure --json --expr '
let
  f = builtins.getFlake "'"$flake"'";
  check = host: system: {
    selectedIsUnstable =
      f.nixosConfigurations.${host}.pkgs.xray.drvPath
      == f.inputs."nixpkgs-unstable".legacyPackages.${system}.xray.drvPath;
    jqRemainsStable =
      f.nixosConfigurations.${host}.pkgs.jq.drvPath
      == f.inputs.nixpkgs.legacyPackages.${system}.jq.drvPath;
  };
in {
  buyan = check "buyan" "x86_64-linux";
  veles = check "veles" "x86_64-linux";
  nixpi = check "nixpi" "aarch64-linux";
}' | jq -e 'all(.[]; .selectedIsUnstable and .jqRemainsStable)'
```

Expected before implementation: the expression returns `false` because Xray is still selected from stable.

- [ ] **Step 2: Define and apply the Xray-only overlay**

In `flake.nix`, define the overlay using the system of the stable package set:

```nix
xrayOverlay = final: prev: {
  xray = inputs.nixpkgs-unstable.legacyPackages.${prev.stdenv.hostPlatform.system}.xray;
};
```

Apply it to NixPi and Buyan in their `nixosConfigurations.*.modules` lists. Add it to Veles's existing per-host overlay list, preserving its `telemt` override and the global stable overlays. Do not add it to `nixpkgsFor` or `nixpkgsUnstableFor` globally.

- [ ] **Step 3: Re-run the package-source check**

Run the command from Step 1 against the updated working tree. Expected: `true`. This proves Xray is from unstable on all three hosts and `jq` remains from stable on each.

## Task 2: Redirect TCP/2053 to the existing SNI-router listener

**Files:**
- Modify: `roles/network/sni-router.nix`
- Modify: `machines/buyan/default.nix`
- Modify: `machines/veles/default.nix`

- [ ] **Step 1: Add a failing firewall-config assertion**

Evaluate `config.networking.firewall.extraCommands` on Buyan and Veles and assert it contains a TCP PREROUTING REDIRECT from 2053 to the configured `roles.sni-router.port` (443). Before the change, this assertion must fail because no redirect is configured.

```bash
for host in buyan veles; do
  nix eval --raw "$flake#nixosConfigurations.$host.config.networking.firewall.extraCommands" | grep -F -- '--dport 2053' | grep -F -- '--to-ports 443'
done
```

- [ ] **Step 2: Add the opt-in redirect option and lifecycle rules**

Add `roles.sni-router.redirectPorts` as `types.listOf types.port`, defaulting to `[ ]`. In `roles.sni-router`:

- Keep Nginx's existing listener at `cfg.port` (default 443).
- Keep `allowedTCPPorts` explicit for both `cfg.port` and each redirect port.
- For each redirect port, install an idempotent rule in `networking.firewall.extraCommands` equivalent to the command below. In the Nix module, prefix `iptables` with `${pkgs.iptables}/bin/` as in `roles/network/wireguard/wireguard-router.nix`:

```bash
${pkgs.iptables}/bin/iptables -t nat -C PREROUTING -p tcp --dport 2053 -j REDIRECT --to-ports 443 2>/dev/null \
  || ${pkgs.iptables}/bin/iptables -t nat -A PREROUTING -p tcp --dport 2053 -j REDIRECT --to-ports 443
```

- In `networking.firewall.extraStopCommands`, remove the same rule only when it exists, using the matching command with `-C` followed by `&&` and the otherwise-identical command with `-D`:

```bash
${pkgs.iptables}/bin/iptables -t nat -C PREROUTING -p tcp --dport 2053 -j REDIRECT --to-ports 443 2>/dev/null \
  && ${pkgs.iptables}/bin/iptables -t nat -D PREROUTING -p tcp --dport 2053 -j REDIRECT --to-ports 443
```
- Do not add an Nginx `listen 2053` directive or any Xray inbound.

Set `roles.sni-router.redirectPorts = [ 2053 ];` on Buyan and Veles. The existing Xray coordinator continues to enable the SNI router and register the existing transport/SNI mappings.

- [ ] **Step 3: Verify the firewall mapping through the NixOS option seam**

For both hosts, assert the evaluated firewall command contains `--dport 2053`, `REDIRECT`, and `--to-ports 443`; assert `allowedTCPPorts` includes 443 and 2053. Also assert `services.nginx.streamConfig` still listens on 443 and does not add a 2053 listener.

```bash
for host in buyan veles; do
  nix eval --json "$flake#nixosConfigurations.$host.config.networking.firewall.allowedTCPPorts" | jq -e 'contains([443,2053])'
  stream=$(nix eval --raw "$flake#nixosConfigurations.$host.config.services.nginx.streamConfig")
  grep -Fq 'listen 443;' <<< "$stream"
  ! grep -Fq 'listen 2053;' <<< "$stream"
done
```

## Task 3: Add Veles's paired outbound candidates to Buyan

**Files:**
- Modify: `roles/network/xray/transports/tcp.nix`
- Modify: `roles/network/xray/transports/grpc.nix`
- Modify: `roles/network/xray/transports/xhttp.nix`
- Modify: `roles/network/xray/relay.nix`
- Modify: `machines/veles/default.nix`

- [ ] **Step 1: Add the outbound-pair assertion before implementation**

Evaluate Veles's `_relayConfig.outbounds` and assert that each enabled VLESS transport has candidates on ports 443 and 2053 with distinct tags. Expected before implementation: the assertion fails because each transport currently has only its 443 outbound.

```bash
nix eval --json "$flake#nixosConfigurations.veles.config.roles.xray._relayConfig.outbounds" | jq -e '([.[] | select(.protocol == "vless") | .settings.vnext[0].port] | sort) == [443,443,443,2053,2053,2053]'
```

- [ ] **Step 2: Make the transport outbound builders accept port and tag overrides**

Keep each builder's existing default tag and port for compatibility. For `mkRelayOutbound`, replace the hard-coded port 443 with an optional `port ? 443` argument and add an optional `tag` argument defaulting to the current tag. Add an optional `tag` argument to `mkClientOutbound` defaulting to its current tag; its port continues to come from `cfg.port`, which the client task can override in the per-outbound config. Do not change `mkSubscriptionEntry` in any transport module.

- [ ] **Step 3: Add the optional relay target backup port and duplicate VLESS outbounds**

Add `roles.xray.relay.target.backupPort` as `types.nullOr types.port`, default `null`, and assert that a configured backup port differs from 443. For each enabled `target.vlessTcp`, `target.vlessGrpc`, and `target.vlessXhttp`, keep the existing primary outbound and, only when `backupPort != null`, add a second outbound using that port. Use these backup tags: `relay-tcp-backup-out`, `relay-grpc-backup-out`, and `relay-xhttp-backup-out`. Add both primary and backup tags to the existing `relay-balancer.selector`; retain its `leastPing` strategy and existing observatory configuration.

Set `roles.xray.relay.target.backupPort = 2053;` in Veles. Do not duplicate Hysteria outbounds; the configured Hysteria target remains disabled and UDP/443 is out of scope.

- [ ] **Step 4: Verify the Veles relay config**

Expected evaluated VLESS outbound ports are `[ 443 443 443 2053 2053 2053 ]`; every outbound tag must appear in `relay-balancer.selector`. Verify the observatory subject selector still covers the new `relay-` tags.

## Task 4: Add NixPi's paired outbound candidates to Veles

**Files:**
- Modify: `roles/network/xray/client.nix`
- Modify: `machines/nixpi/default.nix`

- [ ] **Step 1: Add the client outbound-pair assertion before implementation**

Evaluate `services.xray.settings.outbounds` on NixPi and assert each enabled VLESS transport has one 443 candidate and one 2053 candidate. Expected before implementation: the assertion fails because all three outbounds currently target port 443.

```bash
nix eval --json "$flake#nixosConfigurations.nixpi.config.services.xray.settings.outbounds" | jq -e '([.[] | select(.protocol == "vless") | .settings.vnext[0].port] | sort) == [443,443,443,2053,2053,2053]'
```

- [ ] **Step 2: Add the optional client backup-port option and candidates**

Add `roles.xray.client.backupPort` as `types.nullOr types.port`, default `null`. Assert it differs from every enabled transport's primary port. Preserve each primary outbound; when a backup port is configured, create one additional outbound per enabled transport using the backup port. Use tags `vless-tcp-backup-out`, `vless-grpc-backup-out`, and `vless-xhttp-backup-out`. Include both primary and backup tags in the existing `proxy-balancer.selector`; leave `leastPing`, `observatory.subjectSelector = [ "vless-" ]`, and the 60-second interval unchanged.

Set `roles.xray.client.backupPort = 2053;` on NixPi. Do not change its server address, SNI values, credentials, local listeners, or tunnel configuration.

- [ ] **Step 3: Verify the NixPi client config**

Expected evaluated VLESS outbound ports are `[ 443 443 443 2053 2053 2053 ]`; all six tags must be in `proxy-balancer.selector`, and the observatory selector must cover every tag.

## Task 5: Integrated evaluation and deployment checklist

**Files:**
- All files above
- Do not modify: `roles/network/xray/subscriptions.nix` or the transport `mkSubscriptionEntry` builders.

- [ ] **Step 1: Format all changed Nix files**

Run `nixfmt` on the modified flake, host configurations, SNI-router module, relay/client modules, and three transport modules.

- [ ] **Step 2: Evaluate the accepted invariants**

Using the sanitized flake copy:

1. Buyan and Veles keep their existing VLESS server transport inbounds unchanged; Veles also keeps its existing relay inbounds. No backup inbound is added.
2. The SNI-router config has only its 443 Nginx listener, while the firewall command redirects TCP/2053 to 443 on both hosts.
3. Veles relay and NixPi client each have six VLESS outbound candidates across ports 443 and 2053, and their balancer selectors include every candidate.
4. The subscription generator remains untouched, and its existing emitted VLESS URI port remains 443.
5. Xray package derivations match the unstable input only on Buyan, Veles, and NixPi; other stable packages remain unchanged.

- [ ] **Step 3: Run the flake check**

Run `nix flake check --all-systems "$flake"`. Expected: all NixOS configurations, packages, checks, apps, and dev shells evaluate successfully.

- [ ] **Step 4: Record live-host checks for a separately approved deployment**

Do not deploy as part of plan approval. When deployment is separately requested, first confirm TCP/2053 is available in both VPS provider firewalls. After switching Buyan and Veles, verify the redirect with:

```bash
sudo iptables -t nat -C PREROUTING -p tcp --dport 2053 -j REDIRECT --to-ports 443
```

Verify Nginx still listens only on TCP/443, test Veles and NixPi proxy traffic, and inspect Xray observatory/balancer health before claiming failover works. A health transition may take up to the existing 60-second probe interval; established sessions will not migrate.

## Review Checklist

- The design uses one Nginx stream service and no duplicate Xray server inbounds.
- Firewall REDIRECT rules are idempotent and removed on firewall stop.
- Backup outbounds are opt-in, so unconfigured Xray clients/relays retain their current single-port behavior.
- Both balancer selectors and observatory subject selectors cover the new tags.
- Subscription generation, UDP/443 Hysteria, DNS, and other package sources remain unchanged.
- No commit, deploy, or implementation begins until the user approves this plan.