# Veles Hysteria2 Phase-1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the only Hysteria2 entry point to Veles UDP/443, serve reverse-proxied HTTP/3 masquerade content to unauthenticated probes, and preserve the existing VLESS/REALITY relay to Buyan.

**Architecture:** Xray already supports a Hysteria2 relay inbound whose traffic is sent to `relay-balancer`. Change only the Veles inbound port and masquerade block; it will continue to select the existing VLESS/REALITY outbound routes. Remove Buyan's independent Hysteria2 server inbound, leaving TCP/443 SNI routing unchanged because it does not conflict with UDP/443.

**Tech Stack:** Nix flakes, NixOS, Xray-core Hysteria2 transport, systemd, nftables/NixOS firewall, OpenSSL, curl with HTTP/3 support, Hysteria2-compatible client.

## Global Constraints

- Expose Hysteria2 only on Veles, on UDP port `443`; do not retain UDP/36712.
- Do not change Veles `roles.xray.relay.target.hysteria.enable = false`; Veles-to-Buyan must continue through the existing VLESS/REALITY balancer.
- Set HTTP/3 masquerade to `https://turn.webrtc.yandex.net` and leave `rewriteHost` absent/false.
- Keep the self-signed Veles certificate/key paths; do not enable `insecure=1` in client configuration.
- Do not write a literal fingerprint placeholder into a functional `pinSHA256` field. Distribute the actual pin only after the deployed certificate is available.
- Preserve user-owned uncommitted changes not named in a task.

---

## File map

- Modify: `machines/veles/default.nix` — define the sole public Hysteria2 inbound on UDP/443 and its HTTP/3 masquerade response.
- Modify: `machines/buyan/default.nix` — remove the now-unused Hysteria2 server inbound.
- Modify: `docs/hysteria2-dpi-review.md` — correct the research note's “no files changed” statement if it is retained in the worktree; it is documentation only and must not imply that pinning is deployed by the Nix server.
- No new Nix module or automated test file — the current repository has no Nix test harness. The focused `nix eval` assertions below are the regression checks for this two-machine wiring change.

### Task 1: Move the public Hysteria2 inbound to Veles UDP/443

**Files:**
- Modify: `machines/veles/default.nix:95-101`
- Modify: `machines/buyan/default.nix:87-94`

**Interfaces:**
- Consumes: `roles.xray.relay.hysteria` options from `roles/network/xray/hysteria.nix`: `enable`, `port`, `sni`, `certFile`, `keyFile`, and `masquerade`.
- Produces: Veles's existing `roles.xray.relay.hysteria` inbound at UDP/443 with `streamSettings.hysteriaSettings.masquerade`; Buyan's `_serverConfig.inbounds` no longer contains a `protocol = "hysteria"` entry.

- [ ] **Step 1: Create local evaluation prerequisites without overwriting real secrets**

```bash
if [ ! -f secrets/secrets.json ]; then
  make setup-dummy-secrets
fi
```

Expected: either no output because decrypted secrets already exist, or `secrets/secrets.json` is created from the dummy file.

- [ ] **Step 2: Run the focused checks and record the pre-change failure**

```bash
nix eval --json .#nixosConfigurations.veles.config.roles.xray._relayConfig \
  | jq -e '[.inbounds[] | select(.tag == "hy2-relay-in" and .port == 443)] | length == 1'
nix eval --json .#nixosConfigurations.buyan.config.roles.xray._serverConfig \
  | jq -e '[.inbounds[] | select(.protocol == "hysteria")] | length == 0'
```

Expected before the edit: both commands return non-zero because Veles still uses UDP/36712 and Buyan still has a Hysteria inbound.

- [ ] **Step 3: Replace the Veles Hysteria block with the UDP/443 masquerade configuration**

In `machines/veles/default.nix`, change the existing block to exactly:

```nix
hysteria = {
  enable = true;
  port = 443;
  sni = "turn.webrtc.yandex.net";
  certFile = "/etc/nixos/secrets/hysteria-cert";
  keyFile = "/etc/nixos/secrets/hysteria-key";
  masquerade = {
    type = "proxy";
    url = "https://turn.webrtc.yandex.net";
  };
};
```

Do not add `rewriteHost`; Xray defaults it to `false`. Do not modify the disabled `target.hysteria` block.

- [ ] **Step 4: Remove Buyan's Hysteria server block**

In `machines/buyan/default.nix`, delete exactly this attribute from inside `roles.xray.server`:

```nix
hysteria = {
  enable = true;
  port = 36712;
  sni = "bing.com";
  certFile = "/etc/nixos/secrets/hysteria-cert";
  keyFile = "/etc/nixos/secrets/hysteria-key";
};
```

Leave all three VLESS transport blocks and `reality.privateKeyFile` unchanged.

- [ ] **Step 5: Format the modified Nix files**

```bash
nixfmt machines/veles/default.nix machines/buyan/default.nix
```

Expected: exit status 0; a second identical `nixfmt` run produces no diff.

- [ ] **Step 6: Run focused Nix evaluation checks**

```bash
nix eval --json .#nixosConfigurations.veles.config.roles.xray._relayConfig \
  | jq -e '
      [.inbounds[]
       | select(.tag == "hy2-relay-in")
       | (.port == 443
          and .streamSettings.hysteriaSettings.masquerade
              == {type: "proxy"; url: "https://turn.webrtc.yandex.net"})]
      == [true]'
nix eval --json .#nixosConfigurations.veles.config.networking.firewall.allowedUDPPorts \
  | jq -e 'index(443) != null and index(36712) == null'
nix eval --json .#nixosConfigurations.buyan.config.roles.xray._serverConfig \
  | jq -e '[.inbounds[] | select(.protocol == "hysteria")] | length == 0'
nix eval --json .#nixosConfigurations.buyan.config.networking.firewall.allowedUDPPorts \
  | jq -e 'index(36712) == null'
```

Expected: every command exits 0. The relay module derives its firewall rule from `cfg.hysteria.port`, so no firewall module edit is required.

- [ ] **Step 7: Run repository validation**

```bash
make check
```

Expected: `nix flake check 'path:.' --all-systems` exits 0.

- [ ] **Step 8: Review the diff and commit only the phase-1 wiring**

```bash
git diff --check
git diff -- machines/veles/default.nix machines/buyan/default.nix
git add machines/veles/default.nix machines/buyan/default.nix
git commit -m "feat(xray): move hysteria2 ingress to veles udp 443"
```

Expected: the commit contains only the two machine configuration files. Do not stage pre-existing user changes or untracked research documents unless their task is explicitly completed below.

### Task 2: Deploy Veles and validate masquerade plus certificate pinning

**Files:**
- Modify: none
- Test: deployed Veles host, a trusted client configuration channel, and an external HTTP/3-capable probe host.

**Interfaces:**
- Consumes: Task 1's Veles `hy2-relay-in` at UDP/443 and the certificate at `/etc/nixos/secrets/hysteria-cert`.
- Produces: a real lowercase hexadecimal SHA-256 certificate pin distributed to clients, plus external evidence that unauthenticated HTTP/3 gets proxied content and authenticated Hysteria traffic reaches Buyan.

- [ ] **Step 1: Build the Veles system before switching**

From the repository checkout used to deploy Veles:

```bash
nixos-rebuild build --flake 'path:.#veles'
```

Expected: exit status 0 and a successful system closure build. Do not switch if this command fails.

- [ ] **Step 2: Deploy the reviewed Veles configuration**

On Veles, or through the repository's normal Veles deployment path:

```bash
sudo nixos-rebuild switch --flake 'path:.#veles'
systemctl --no-pager --full status xray
sudo ss -ulnp | grep -E ':(443|36712)\b' || true
```

Expected: `xray` is active and listening on UDP/443; no process is listening on UDP/36712 for Hysteria.

- [ ] **Step 3: Compute the exact Xray certificate pin from the deployed certificate**

On Veles, calculate and retain the SHA-256 hash of the certificate's DER encoding:

```bash
PIN="$(sudo openssl x509 -in /etc/nixos/secrets/hysteria-cert -outform DER \
  | openssl dgst -sha256 -hex \
  | awk '{print $2}')"
printf '%s\n' "$PIN"
test "${#PIN}" -eq 64
```

Expected: the final command exits 0 and `PIN` contains one 64-character hexadecimal string. Treat it as a secret-distribution configuration value even though it is derived from the public certificate. Store it in the trusted client configuration channel; do not add it as a fake server-side placeholder.

- [ ] **Step 4: Test the unauthenticated HTTP/3 masquerade response externally**

From an external host with HTTP/3-enabled curl, enter Veles's public IPv4 address when prompted:

```bash
read -r -p 'Veles public IPv4: ' VELES_PUBLIC_IP
curl --http3-only --insecure \
  --resolve "turn.webrtc.yandex.net:443:${VELES_PUBLIC_IP}" \
  -D - -o /dev/null https://turn.webrtc.yandex.net/
```

Expected: an HTTP response from the proxied target, not Xray's default `404 Not Found`. `--insecure` is used only for this unauthenticated probe because the endpoint is intentionally self-signed; it must not appear in the Hysteria client configuration.

- [ ] **Step 5: Test authenticated client access with the real pin**

On the trusted client-configuration workstation, enter the per-user Hysteria password when prompted and produce the pinned URI from the actual values collected in Steps 3 and 4:

```bash
read -rs -p 'Hysteria password: ' HYSTERIA_AUTH
echo
printf 'hysteria2://%s@%s:443/?sni=turn.webrtc.yandex.net&pinSHA256=%s#veles-hysteria2\n' \
  "$HYSTERIA_AUTH" "$VELES_PUBLIC_IP" "$PIN"
```

Import the resulting URI into a Hysteria2-compatible client and establish a proxy request. Expected: authenticated traffic reaches the internet through Veles and Buyan. Confirm the client does not add `insecure=1`.

- [ ] **Step 6: Perform the negative pin test**

Change one hexadecimal character in a disposable copy of the client pin and reconnect.

Expected: TLS/certificate verification fails before proxy traffic is established. Restore the exact pin after confirming failure.

- [ ] **Step 7: Confirm no Hysteria listener remains on Buyan**

After deploying the Buyan configuration through its normal deployment path:

```bash
sudo nixos-rebuild switch --flake 'path:.#buyan'
sudo ss -ulnp | grep ':36712\b' || true
```

Expected: no Hysteria process listens on UDP/36712. Existing VLESS/REALITY service remains active.

### Task 3: Align the research note with the implemented scope

**Files:**
- Modify: `docs/hysteria2-dpi-review.md`

**Interfaces:**
- Consumes: Task 1's committed machine configuration and Task 2's deployment facts.
- Produces: a research note that accurately states it is documentation and does not claim Nix configuration was untouched.

- [ ] **Step 1: Inspect the note's status claim and current deployment conclusion**

```bash
rg -n 'no files changed|36712|masquerade|self-signed|pin' docs/hysteria2-dpi-review.md
```

Expected: identify the obsolete “no files changed” wording and any port-specific finding that no longer describes the intended configuration.

- [ ] **Step 2: Update only the stale repository-review statements**

Replace the note's claim that no files changed with wording that it records the pre-hardening review. Update the finding for UDP/36712 to say it was removed in the Veles phase-1 change, and retain the documented limitation that a pinned self-signed certificate for a third-party SNI is not normal public HTTPS.

Use this replacement text for the conclusion paragraph:

```markdown
The Veles phase-1 configuration moves the Hysteria2 ingress to UDP/443 and
adds reverse-proxy masquerade. It improves the endpoint's unauthenticated
HTTP/3 response over the earlier default-404 configuration, but a self-signed
certificate pinned by clients while claiming a third-party SNI remains
observable to active probes and is not equivalent to publicly trusted HTTPS.
```

- [ ] **Step 3: Verify documentation consistency and commit it separately**

```bash
rg -n 'no files changed|UDP/36712.*current repo|insecure=1.*client configuration' \
  docs/hysteria2-dpi-review.md && exit 1 || true
git diff --check
git add docs/hysteria2-dpi-review.md
git commit -m "docs: update hysteria2 dpi review after veles hardening"
```

Expected: the stale phrases are absent, whitespace validation passes, and the documentation commit is separate from the operational configuration change.
