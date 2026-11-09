# Machine and Workload Separation Implementation Plan

> **For agentic workers:** Implement only after the user approves execution. Work in the designated feature worktree. The checkboxes track reviewable steps; do not commit or deploy unless the user explicitly requests it.

**Goal:** Separate machine setup from deployed workloads and deduplicate the existing relay and Tailscale client deployments without changing evaluated behavior.

**Architecture:** Each host directory composes a machine module and workload module; reusable service behavior remains in existing roles. Two explicitly imported modules contain the current shared relay and client deployment policy, never globally enabled defaults.

**Tech stack:** NixOS modules, Nix flakes, nixfmt, Bash, jq, Python unittest.

**Spec:** `docs/superpowers/specs/2026-11-09-machine-workload-separation-design.md`.

## Global constraints

- Preserve all five NixOS host behaviors, their overlays, `do-generic`, role option defaults, and the existing generic role interfaces. This work does not deploy any host.
- Preserve Stribog's `23.11` state version, `/32` networking, and key-based root login; preserve every other machine's own version, networking, SSH, boot and disks.
- Preserve Xray fail-closed reverse mode, manual forward rollback, CDN isolation, SNI ordering, credentials paths, metrics, firewall and bridge identity. Shared deployment policy must not activate through generic role auto-discovery.
- Never expose or copy real secrets. The comparison uses only dummy secrets in two worktrees; do not overwrite an existing `secrets/secrets.json`. Do not use `path:.` with real secrets.
- List-valued Nix options merge. Move rather than duplicate list definitions; do not use `mkForce` to conceal duplication.
- Leave historical specifications and plans intact. Update current README, `AGENTS.md`, and the active Xray deployment runbook.

## File map

| Path | Responsibility |
|---|---|
| `machines/{buyan,veles,stribog,mokosh,nixpi}/default.nix` | Compose the two local modules; pass any static host facts needed by both. |
| `machines/{buyan,veles,stribog,mokosh,nixpi}/configuration.nix` | Platform imports, identity, boot, network, storage, host services and state version. |
| `machines/{buyan,veles,stribog,mokosh,nixpi}/workloads.nix` | Workload imports, role selection and native workload services. |
| `roles/network/xray/profiles/reverse-relay.nix` | Explicitly imported Veles/Stribog deployment profile, not an Xray role default. |
| `common/tailscale-client.nix` | Explicitly imported Buyan/Veles/Stribog Tailscale client configuration. |
| `README.md`, `AGENTS.md`, `docs/xray-reverse-deployment.md` | Current layout, guidance and operational paths. |

No changes to `flake.nix`, `hardware/`, the `do-generic` output or role defaults are planned. If an actual role defect emerges, stop and agree on a separate change rather than broadening this refactor.

### Task 1: Prepare a dummy-only baseline and comparison

**Files:** No tracked files created. `roles/network/xray/tests/reverse.sh` is the existing regression test.

**Interfaces:** Input is this feature worktree and the original `HEAD`; outputs are a temporary baseline checkout and private JSON projections, not committed fixtures. Both trees must contain the same dummy `secrets/secrets.json`.

- [ ] **Step 1: Establish safe workspaces.** In the implementation worktree, confirm the current `secrets/secrets.json` is absent or byte-identical to `secrets/secrets.dummy.json`. If absent, run `make setup-dummy-secrets`; if present but different, stop and ask instead of overwriting. In a shell retained for the whole plan, run:

```bash
set -euo pipefail
candidate="$(pwd -P)"
if [ -e secrets/secrets.json ]; then
  cmp -s secrets/secrets.json secrets/secrets.dummy.json || { echo 'Non-dummy secrets: stop' >&2; exit 1; }
else
  make setup-dummy-secrets
fi
tmp="$(mktemp -d)"
tmp="$(cd "$tmp" && pwd -P)"
chmod 700 "$tmp"
git worktree add --detach "$tmp/baseline" HEAD
(cd "$tmp/baseline" && make setup-dummy-secrets)
base="$tmp/baseline"
```

Keep both worktrees and `$tmp` until final verification. If the shell is restarted, restore these variables to the same paths; never substitute a production checkout.

- [ ] **Step 2: Capture the baseline.** Run these commands from the candidate worktree. The projection includes dummy proxy identities, so never print or commit the JSON. The selected fields are a regression net, not a proof of complete equality.

```bash
cat > "$tmp/projection.nix" <<'NIX'
let
  f = builtins.getFlake ("path:" + builtins.getEnv "TREE");
  hosts = [ "buyan" "veles" "stribog" "mokosh" "nixpi" ];
  workloadPaths = {
    mokosh = [
      [ "roles" "hardened" "enable" ]
      [ "roles" "vpn" "enable" ] [ "roles" "vpn" "hostname" ]
      [ "roles" "vpn" "certificateDirectory" ] [ "roles" "vpn" "publicIPv4" ]
      [ "roles" "mail" "enable" ] [ "roles" "mail" "sesSmtpUsername" ]
      [ "roles" "mail" "sslCertificatesDirectory" ] [ "roles" "mail" "hostname" ]
      [ "roles" "webmail" "enable" ] [ "roles" "webmail" "baseDomain" ]
      [ "roles" "webmail" "jmapServerUrl" ] [ "roles" "webmail" "sessionSecretFile" ]
      [ "roles" "letsencrypt" "enable" ] [ "roles" "letsencrypt" "domains" ]
      [ "roles" "wireguardRouter" "enable" ] [ "roles" "wireguardRouter" "externalIf" ]
      [ "roles" "wireguardRouter" "clients" ]
      [ "roles" "vault" "enable" ] [ "roles" "vault" "baseDomain" ] [ "roles" "vault" "enableWeb" ]
      [ "roles" "shadowsocks-server" "enable" ] [ "roles" "shadowsocks-server" "openFirewall" ]
      [ "roles" "shadowsocks-server" "baseDomain" ] [ "roles" "shadowsocks-server" "enableWeb" ]
      [ "roles" "calibre" "enable" ] [ "roles" "calibre" "baseDomain" ]
      [ "roles" "readeck" "enable" ] [ "roles" "readeck" "baseDomain" ]
      [ "roles" "anytype-mcp" "enable" ] [ "roles" "anytype-mcp" "baseDomain" ]
      [ "roles" "rss" "enable" ] [ "roles" "rss" "hub" "enable" ] [ "roles" "rss" "baseDomain" ]
      [ "roles" "rss" "summarizer" "enable" ] [ "roles" "rss" "summarizer" "llmApiKeyFile" ]
      [ "roles" "rss" "summarizer" "minifluxApiKey" ] [ "roles" "rss" "summarizer" "dailyTargetFeedId" ]
      [ "roles" "rss" "summarizer" "weeklySourceFeedId" ] [ "roles" "rss" "summarizer" "weeklyTargetFeedId" ]
      [ "roles" "rss" "summarizer" "monthlySourceFeedId" ] [ "roles" "rss" "summarizer" "monthlyTargetFeedId" ]
      [ "roles" "backup" "enable" ] [ "roles" "backup" "repository" ]
      [ "roles" "backup" "passwordFile" ] [ "roles" "backup" "environmentFile" ]
    ];
    nixpi = [
      [ "roles" "share" "enable" ] [ "roles" "share" "hostname" ] [ "roles" "share" "enableTimeMachine" ]
      [ "roles" "media" "enable" ] [ "roles" "torrent" "enable" ]
      [ "roles" "dns" "enable" ] [ "roles" "dns" "openFirewall" ] [ "roles" "dns" "useLocalDNS" ]
      [ "roles" "dns" "ipAddress" ] [ "roles" "dns" "metrics" "enable" ]
      [ "roles" "dhcp" "enable" ] [ "roles" "dhcp" "openFirewall" ] [ "roles" "dhcp" "hostMAC" ]
      [ "roles" "dhcp" "hostIP" ] [ "roles" "dhcp" "gatewayIP" ]
      [ "roles" "shadowsocks-client" "enable" ] [ "roles" "shadowsocks-client" "host" ]
      [ "roles" "shadowsocks-client" "openFirewall" ]
      [ "roles" "wireguard-client" "enable" ] [ "roles" "wireguard-client" "ip" ]
      [ "roles" "wireguard-client" "endpoint" ] [ "roles" "wireguard-client" "serverPubKey" ]
      [ "roles" "home-nginx" "enable" ] [ "roles" "home-nginx" "ip" ]
      [ "roles" "photos" "enable" ] [ "roles" "photos" "storagePath" ] [ "roles" "zeroconf" "enable" ]
    ];
    buyan = [ [ "roles" "hardened" "enable" ] ];
    veles = [ [ "roles" "hardened" "enable" ] ];
    stribog = [ [ "roles" "hardened" "enable" ] ];
  };
  project = host:
    let
      n = f.nixosConfigurations.${host};
      c = n.config;
      service = c.systemd.services.tailscaled-autoconnect or { };
    in {
      inherit (c.system) stateVersion;
      boot = {
        grub = c.boot.loader.grub.device;
        initrdSystemd = c.boot.initrd.systemd.enable;
        sysctl = c.boot.kernel.sysctl;
      };
      fileSystems = c.fileSystems;
      swapDevices = map (s: { inherit (s) device size; }) c.swapDevices;
      networking = {
        inherit (c.networking) hostName useDHCP nameservers defaultGateway defaultGateway6;
        interfaces = builtins.mapAttrs (_: i: {
          inherit (i.ipv4) addresses routes;
          ipv6 = { inherit (i.ipv6) addresses routes; };
        }) c.networking.interfaces;
        firewall = {
          inherit (c.networking.firewall) enable allowPing allowedTCPPorts allowedUDPPorts;
        };
      };
      ssh = c.services.openssh.settings;
      rootKeys = c.users.users.root.openssh.authorizedKeys.keys;
      tailscale = {
        inherit (c.services.tailscale) enable openFirewall authKeyFile extraUpFlags extraSetFlags disableUpstreamLogging;
        after = service.after or [ ];
        wants = service.wants or [ ];
        serviceConfig = service.serviceConfig or { };
      };
      sni = {
        inherit (c.roles.sni-router) enable entries redirectPorts defaultBackend;
      };
      forward = { inherit (c.roles.stream-forwarder) enable forwards; };
      inherit (c.roles.xray) _configTemplate;
      clientSettings = if c.roles.xray.client.enable then c.services.xray.settings else null;
      forwardTemplate = if c.roles.xray.relay.enable then
        (n.extendModules { modules = [ { roles.xray.relay.egress.via = n.lib.mkForce "forward"; } ]; }).config.roles.xray._configTemplate
        else null;
      workloads = builtins.listToAttrs (map (path: {
        name = builtins.concatStringsSep "." path;
        value = n.lib.getAttrFromPath path c;
      }) workloadPaths.${host});
      relay = if c.roles.xray.relay.enable then {
        ingress = {
          inherit (c.roles.xray.relay.ingress) users reality hysteria2;
          vless = {
            inherit (c.roles.xray.relay.ingress.vless) raw grpc xhttp;
            cdnXhttp = if c.roles.xray.relay.ingress.vless.cdnXhttp.enable
              then c.roles.xray.relay.ingress.vless.cdnXhttp
              else { enable = false; };
          };
        };
        inherit (c.roles.xray.relay) egress;
      } else null;
      metrics = { inherit (c.roles.xray.metrics) enable listen; };
      observability = {
        inherit (c.roles.observability) enable remoteAgents remoteScrapeJobs;
        agentEnable = c.roles.observability.agent.enable;
      };
    };
in builtins.listToAttrs (map (host: { name = host; value = project host; }) hosts)
NIX
TREE="$base" nix eval --impure --json --file "$tmp/projection.nix" > "$tmp/baseline.json"
(cd "$base" && make check && bash roles/network/xray/tests/reverse.sh "path:$base")
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests/vulnerability -v
```

If any projected option cannot be serialized, narrow that field to explicit meaningful subfields on **both** sides; document what was excluded. Do not swallow evaluation failures. If baseline tests fail, stop and report them before refactoring.

- [ ] **Step 3: Force all baseline host derivations.** This evaluates rather than builds the five NixOS systems:

```bash
for host in buyan veles stribog mokosh nixpi; do
  nix eval --raw "path:$base#nixosConfigurations.$host.config.system.build.toplevel.drvPath" >/dev/null
done
```

### Task 2: Split machine setup and workloads without extraction

**Files:** Modify the five `machines/<host>/default.nix` files; create each host's `configuration.nix` and `workloads.nix`.

**Interfaces:** `default.nix` is the flake import. Both children are NixOS modules. For NixPi pass `{ ifname = "end0"; ip = "192.168.0.20"; gatewayIP = "192.168.0.1"; }` to the two module factories; for Mokosh pass `{ ifname = "eth0"; }` to both, avoiding derivation of a host fact from merged address lists. A factory has the shape `{ ifname, ip, gatewayIP }: { config, lib, ... }: { ... }` for NixPi; use the corresponding one-argument factory for Mokosh. Other hosts can use plain imported modules. `config.networking.hostName` supplies workload hostname where needed.

- [ ] **Step 1: Split NixPi and Mokosh.** Use this composition shape in each `default.nix`, changing the facts to the exact host values noted above:

```nix
let
  facts = { ifname = "end0"; ip = "192.168.0.20"; gatewayIP = "192.168.0.1"; };
in
{
  imports = [
    (import ./configuration.nix facts)
    (import ./workloads.nix facts)
  ];
}
```

Move platform imports, host settings, storage services, system version and journald to `configuration.nix`. Move workload definitions to `workloads.nix`, including Tailscale, its autoconnect systemd overrides, all `roles.*` assignments and their necessary secrets/local bindings. Preserve `../../roles`, hardening, cache, server, zeroconf and Btrfs imports in the module where they are needed; no new role selection is implied. Carry the exact NixPi gateway, disk paths and share/DNS/DHCP inputs over unchanged. Keep Mokosh's Headscale ordering and every WireGuard client unchanged.

- [ ] **Step 2: Split Buyan, Veles and Stribog.** Their `default.nix` imports `./configuration.nix` and `./workloads.nix`. Move all platform/OS/SSH/network settings and `system.stateVersion` to `configuration.nix`; move roles, Tailscale and its autoconnect override plus their required `let` bindings to `workloads.nix`. Replace workload-only `hostname` literals with `config.networking.hostName`; keep `configuration.nix`'s host name explicit. Do not extract common settings yet.

- [ ] **Step 3: Verify the mechanical split.** Format only the changed Nix files, run the comparison and Xray regression:

```bash
nixfmt machines/{buyan,veles,stribog,mokosh,nixpi}/*.nix
TREE="$candidate" nix eval --impure --json --file "$tmp/projection.nix" > "$tmp/split.json"
cmp "$tmp/baseline.json" "$tmp/split.json"
bash roles/network/xray/tests/reverse.sh "path:$candidate"
```

Expected: `cmp` and the regression script exit zero. If not, investigate the precise changed definition using dummy data privately; do not proceed until explained and corrected.

### Task 3: Extract shared Tailscale client deployment

**Files:** Create `common/tailscale-client.nix`; modify Buyan, Veles and Stribog `workloads.nix`.

**Interfaces:** A plain NixOS module, imported explicitly by those three workload modules; it declares no new option and leaves Mokosh and NixPi untouched.

- [ ] **Step 1: Create the shared module.** Move the exact common assignments:

```nix
{
  services.tailscale = {
    enable = true;
    openFirewall = true;
    authKeyFile = "/etc/nixos/secrets/tailscale-auth-key";
    extraUpFlags = [
      "--login-server=https://headscale.uspenskiy.tech"
      "--accept-dns=false"
    ];
    extraSetFlags = [ "--accept-dns=false" ];
  };

  systemd.services.tailscaled-autoconnect.serviceConfig = {
    Restart = "on-failure";
    RestartSec = "30s";
  };
}
```

- [ ] **Step 2: Import it and remove the original three blocks.** Each of the three `workloads.nix` modules adds `../../common/tailscale-client.nix` to its `imports`; do not leave the original flags or restart definitions in the hosts. Do not add the import on Mokosh or NixPi.

- [ ] **Step 3: Verify.**

```bash
nixfmt common/tailscale-client.nix machines/{buyan,veles,stribog}/workloads.nix
TREE="$candidate" nix eval --impure --json --file "$tmp/projection.nix" > "$tmp/tailscale.json"
cmp "$tmp/baseline.json" "$tmp/tailscale.json"
bash roles/network/xray/tests/reverse.sh "path:$candidate"
```

### Task 4: Extract the explicitly imported Xray relay deployment

**Files:** Create `roles/network/xray/profiles/reverse-relay.nix`; modify Veles and Stribog `workloads.nix`. Do not add an import to `roles/network/xray/default.nix`.

**Interfaces:** The profile is a NixOS module consuming `config.networking.hostName`, `lib`, `../../../../secrets`, `../../../../common/filter-proxy-users.nix`, and `../../../../common/select-proxy-user.nix`. It sets existing `roles.*` options; it creates no new option. Host workload modules explicitly import `../../roles/network/xray/profiles/reverse-relay.nix`.

- [ ] **Step 1: Create the profile's bindings.** This is the exact identity-selection interface; preserve the helpers' missing/duplicate-user failures:

```nix
{ config, lib, ... }:
let
  hostname = config.networking.hostName;
  secrets = import ../../../../secrets;
  filterProxyUsersForHost = import ../../../../common/filter-proxy-users.nix { inherit lib; };
  selectProxyUser = import ../../../../common/select-proxy-user.nix;
  users = filterProxyUsersForHost hostname secrets.singBoxUsers;
  reverseUser = selectProxyUser "buyan" users;
  relayUser = selectProxyUser hostname secrets.singBoxUsers;
in
{
  # Move the common settings described in Step 2 here.
}
```

- [ ] **Step 2: Move identical settings, not copies.** From the two pre-extraction workload modules, move to the profile: `roles.xray.metrics.enable`, the common `roles.xray.relay` ingress users/REALITY/VLESS/Hysteria2 settings, reverse and common forward settings, `roles.sni-router.redirectPorts = [ 2053 ];`, and `roles.stream-forwarder` targeting `${secrets.ip.mokosh.address}:443`. Preserve all exact values and enabled states, including `egress.via = "reverse"`, forward server, REALITY key/short ID/fingerprint, VLESS SNIs, ports and credential paths. Keep the Veles-only `ingress.vless.cdnXhttp` block and Veles's explicit `egress.forward.hysteria2` block in Veles's workload; Stribog must retain its original defaults. Do not merge `ingress.users` or other lists from multiple sources. Keep `roles.observability.agent.enable` explicitly in both hosts and Buyan.

- [ ] **Step 3: Verify isolation and output.**

```bash
nixfmt roles/network/xray/profiles/reverse-relay.nix machines/{veles,stribog}/workloads.nix
TREE="$candidate" nix eval --impure --json --file "$tmp/projection.nix" > "$tmp/relay.json"
cmp "$tmp/baseline.json" "$tmp/relay.json"
bash roles/network/xray/tests/reverse.sh "path:$candidate"
```

Expected: unchanged projections and all existing assertions, including Buyan bridge parity, both relays, disabled CDN, Stribog identity and manual forward mode. Check the diff to ensure no profile import is added to `roles/network/xray/default.nix` and no other host imports it. The profile's location is safe because `roles/default.nix` imports the existing Xray directory `default.nix` rather than recursively scanning below it.

### Task 5: Documentation and final validation

**Files:** Modify `README.md`, `AGENTS.md`, `docs/xray-reverse-deployment.md`.

- [ ] **Step 1: Update current guidance.** Describe the three-file host layout, explicit shared profiles and reusable role rule in README and AGENTS. Update the Xray runbook's temporary `egress.via` edit to point to the actual new file containing that setting. Its `git diff --exit-code` gate must cover `machines/veles/default.nix`, `machines/veles/configuration.nix`, `machines/veles/workloads.nix`, `roles/network/xray/profiles/reverse-relay.nix`, and the original `roles/network/xray/relay.nix` and `roles/network/xray/server.nix`. If the common profile owns the setting, explicitly warn that the temporary source edit affects both relay configurations in that checkout, and still instruct activating only Veles. Do not update historical plans or imply a deployment occurred.
- [ ] **Step 2: Run final checks.**

```bash
TREE="$candidate" nix eval --impure --json --file "$tmp/projection.nix" > "$tmp/final.json"
cmp "$tmp/baseline.json" "$tmp/final.json"
for host in buyan veles stribog mokosh nixpi; do
  nix eval --raw "path:$candidate#nixosConfigurations.$host.config.system.build.toplevel.drvPath" >/dev/null
done
make check
bash roles/network/xray/tests/reverse.sh "path:$candidate"
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests/vulnerability -v
find machines roles/network/xray/profiles common -name '*.nix' -exec nixfmt --check {} +
git diff --check
git status --short
```

Host derivation paths need not match the baseline because source locations can affect paths; projection equality, regression checks and focused diff review are the relevant evidence. Record the local platform and any checks not built (for example `nix flake check` may evaluate other systems without building their checks). Do not claim a live deployment test.

- [ ] **Step 3: Remove only the temporary baseline worktree and comparison files after recording results.**

```bash
git worktree remove "$base"
rm -rf "$tmp"
```

The feature worktree and its uncommitted changes stay available for review. Do not commit, push, run `nixos-rebuild switch`, or alter DNS without separate authorization.
