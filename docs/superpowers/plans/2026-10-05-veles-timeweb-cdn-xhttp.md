# Veles Timeweb CDN XHTTP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an encrypted XHTTP ingress and plausible static HTTPS origin on Veles for Timeweb's issued CDN hostname without moving existing clients or changing Buyan's direct reverse links.

**Architecture:** Reuse the existing Veles Xray process and Nginx stream/SNI router. Route the origin SNI through the same Nginx instance to its loopback HTTPS virtual host, which serves a static page or forwards only `/vl-cdn` to a loopback XHTTP/VLESS-Encryption inbound; route that inbound through the existing relay balancer. NixOS HTTP-01 ACME handles the origin certificate, and systemd `LoadCredential` injects the VLESS decryption value at runtime.

**Tech Stack:** NixOS flake (locked nixpkgs), Xray 26.9.9 from the existing overlay, Nginx stream+HTTP, NixOS ACME, systemd credentials, jq, bash, nixfmt.

**Spec:** `docs/superpowers/specs/2026-10-05-veles-timeweb-cdn-xhttp-design.md`

## Global Constraints

- Preserve Veles REALITY RAW/gRPC/XHTTP, Hysteria2, TCP/2053 redirect, Buyan's direct IP + REALITY reverse links, Buyan public inbounds, and NixPi's direct Veles address/configuration. No new public port, second Xray/Nginx instance, dependency, proxy fallback or automatic client cutover.
- The Timeweb-issued `*.cdn.twcstorage.ru` hostname is the **client** address/SNI. `sunny-bee-on-the-flower.net.by` is the **HTTPS origin**, with a Timeweb DNS apex A record to Veles and **no** AAAA while Veles IPv6 is disabled. The origin A record exposes Veles's IP; do not claim otherwise. Do not touch the Cloudflare-only `dns/` files.
- The new loopback inbound is XHTTP `packet-up` with **VLESS Encryption**, not REALITY/TLS inside Xray. Clients validate the Timeweb edge TLS certificate; Veles presents a valid public origin certificate over Timeweb→Veles HTTPS, but provider-side certificate verification must be confirmed during the live gate. Only the new inbound uses the encryption pair. Existing inbounds remain untouched; Buyan's reverse-only identity is excluded from the new inbound's users.
- Timeweb documents only GET/HEAD/OPTIONS. `uplinkHTTPMethod = "GET"` is a **client** setting; document it for a separately configured client, not NixPi. No preset or Timeweb-specific server option. CDN caching/streaming behavior is unproven until live tests.
- Private VLESS decryption material stays out of Nix evaluation, the store, client examples, command-line arguments and logs. The operator alone runs `xray vlessenc` and installs the real pair as the **last implementation handoff before deployment**. Do not generate even a disposable keypair for this plan. An absent/invalid credential must prevent startup, never select `"none"`.
- The HTTP origin serves a minimal static `/`, ordinary static 404 elsewhere (including invalid XHTTP 4xx probes), and passes valid `/vl-cdn` sessions without buffering/caching. A page is camouflage, not a guarantee against active probing.
- All implementation checks use committed dummy secrets in a **separate isolated checkout**. `secrets/secrets.json` exists (ignored) in the current checkout: never run `make setup-dummy-secrets` here or read, print, stage or overwrite real credentials. No code editing, deployment, key creation, commit or push is authorized by this plan-writing request.

---

## Files and task boundaries

- `roles/network/xray/relay.nix`: new `ingress.vless.cdnXhttp` options, XHTTP inbound and routing; later the same owning role supplies the Nginx origin/ACME config. No new role or generic transport registry.
- `roles/network/xray/default.nix`: skip the non-REALITY inbound when building REALITY SNI entries, append the origin SNI entry after existing entries, and extend runtime credential injection. Do not change `roles/network/sni-router.nix`: its global `proxy_protocol on` is already what the local HTTPS listener needs.
- `machines/veles/default.nix`: enable only this additive ingress with the exact origin, path and secret-file path. Do not modify `machines/buyan/default.nix` or `machines/nixpi/default.nix`.
- `roles/network/xray/tests/reverse.sh`: extend the existing eval/regression suite, including a disabled-option negative variant. Do not create a second test runner.
- `docs/proxy.md`: add the optional CDN branch to the *proposed* topology; preserve its not-deployed warning.
- Create `docs/veles-timeweb-cdn-deployment.md`: human-operated Timeweb DNS/CDN setup, keypair handoff, independent runtime go/no-go and rollback; distinct from the existing reverse-relay runbook.
- `secrets/unlocked/spec.txt` is **tracked** (whitelisted by `secrets/unlocked/.gitignore`) and **not** edited by the implementation agent. Only the human later adds the non-secret filename/permission mapping and manages the encrypted archive during the final handoff; staging that mapping is a deliberate human decision, never an implicit add-all. Never create a plaintext fixture in the repository.

**Before any implementation:** ask the user whether to create a worktree or a regular feature branch from `main` under the repository's `AGENTS.md` git policy. The spec and plan are currently untracked on `main`; explicitly bring both reviewed documents into the chosen implementation checkout before running the checks. Create `secrets/secrets.json` from `secrets/secrets.dummy.json` only if it is absent **in that isolated checkout**, and do not copy a real ignored file into it. No step below is a request to commit.

### Task 1: Add the VLESS-encrypted loopback ingress and runtime-secret gate

**Files:** Modify `roles/network/xray/relay.nix`, `roles/network/xray/default.nix`, `machines/veles/default.nix`; test in `roles/network/xray/tests/reverse.sh`.

**Interfaces:** Produce `roles.xray.relay.ingress.vless.cdnXhttp.{enable,originDomain,path,decryptionFile}` (`enable` defaults false, `path` defaults `"/vl-cdn"`; domain and runtime file path are required when enabled); the generated inbound tag is `vless-cdn-xhttp-in`, listener `127.0.0.1:9013`, with `settings.decryption = "@VLESS_CDN_DECRYPTION@"` until runtime. The coordinator consumes `decryptionFile` using `LoadCredential = "cdn-decryption:<path>"` on the active relay only and writes the value into the private config **before** Xray `-test`. No public SNI route is added until Task 2; the tree remains evaluable but this partial tree must not be deployed.

- [ ] **Step 1: Write the red regression checks** in `reverse.sh` before changing any role. Update every existing strict Veles inbound-tag and reverse/forward routing tag list to include `"vless-cdn-xhttp-in"` (the topology, reverse-routing and forward-routing assertions that currently list four inbound tags must include the fifth). Add this predicate using the script's existing `veles` JSON and `reverseId` dummy UUID:

```bash
printf '%s' "$veles" | jq -e --arg id "$reverseId" '
  . as $cfg |
  ([.inbounds[] | select(.tag == "vless-cdn-xhttp-in")] | length == 1)
  and ([$cfg.inbounds[] | select(.tag == "vless-cdn-xhttp-in") |
    .listen, .port, .protocol, .streamSettings.network,
    .streamSettings.security, .streamSettings.xhttpSettings.mode,
    .streamSettings.xhttpSettings.path, .settings.decryption] ==
    ["127.0.0.1", 9013, "vless", "xhttp", "none", "packet-up", "/vl-cdn", "@VLESS_CDN_DECRYPTION@"])
  and ([.inbounds[] | select(.tag == "vless-cdn-xhttp-in") | .settings.clients[] | select(.id == $id or .reverse? != null)] | length == 0)
  and ([.routing.rules[] | select((.inboundTag // []) | index("vless-cdn-xhttp-in")) | .balancerTag] == ["reverse-balancer"])
  and ([.outbounds[].tag] == ["blocked-out"])
' >/dev/null
```

Also assert the new inbound's sorted client IDs equal the existing gRPC inbound's sorted client IDs (both use `normalUsers`); assert original RAW/gRPC/xHTTP/Hy2 ingress SNIs, client identities and Buyan bridge settings remain as in the existing tests. Do not print UUIDs or raw config. Use `nix eval --json "$flake#nixosConfigurations.veles.config.systemd.services.xray.serviceConfig.LoadCredential" | jq -e 'any(.[]; . == "cdn-decryption:/etc/nixos/secrets/vlessenc-decryption-key")' >/dev/null` and inspect the service script for `--rawfile decryption` rather than `--arg decryption`.

- [ ] **Step 2: Confirm red.** In the isolated checkout run `bash roles/network/xray/tests/reverse.sh "path:$(pwd -P)"` (the script assumes dummy secrets). Expect the newly added assertion to fail because the inbound/credential is missing, not an unrelated evaluation or missing-tool failure.

- [ ] **Step 3: Add the minimal role option and inbound** in `relay.nix`. The new inbound must not use `vless.mkInbound`, which hardcodes REALITY and `acceptProxyProtocol = true`; Nginx HTTP proxying into 9013 sends neither REALITY nor the PROXY prefix. Use the existing `vlessClients.plain` (already excludes Buyan):

```nix
cdnCfg = ingressCfg.vless.cdnXhttp;
cdnEnabled = cdnCfg.enable;
cdnInbound = {
  listen = "127.0.0.1";
  port = 9013;
  tag = "vless-cdn-xhttp-in";
  protocol = "vless";
  settings = {
    clients = vlessClients.plain;
    decryption = "@VLESS_CDN_DECRYPTION@";
  };
  streamSettings = {
    network = "xhttp";
    security = "none";
    xhttpSettings = {
      path = cdnCfg.path;
      mode = "packet-up";
    };
  };
};
```

Add `optional cdnEnabled cdnInbound` to `relayConfig.inbounds` and `optional cdnEnabled cdnInbound.tag` to `ingressTags`, in both egress modes. Under `options.roles.xray.relay.ingress.vless.cdnXhttp`, use `mkEnableOption`, `types.str` for origin/path and `types.path` for the installed secret file. Add a conditional assertion that domain and file are nonempty and path starts with `/`, is not `/`, and does not end in `/`; require the origin SNI to differ from every enabled REALITY ingress SNI. Supply the machine inputs:

```nix
roles.xray.relay.ingress.vless.cdnXhttp = {
  enable = true;
  originDomain = "sunny-bee-on-the-flower.net.by";
  path = "/vl-cdn";
  decryptionFile = "/etc/nixos/secrets/vlessenc-decryption-key";
};
```

- [ ] **Step 4: Adapt shared coordinator safely.** `default.nix` currently maps *every* VLESS inbound to `.streamSettings.realitySettings.serverNames`; filter to `(inbound.streamSettings.security or "") == "reality"` as well as `protocol == "vless"`. Keep the three existing SNI entries in the same order and the existing `defaultBackend`. Gate credential loading on `relayCfg.enable && relayCfg.ingress.vless.cdnXhttp.enable`:

```nix
cdnEnabled = relayCfg.enable && relayCfg.ingress.vless.cdnXhttp.enable;
# Append to the existing LoadCredential expression:
++ optional cdnEnabled "cdn-decryption:${relayCfg.ingress.vless.cdnXhttp.decryptionFile}"
```

In the existing private `jq` render, select the credential *path*, not its value, with Nix interpolation in the service script:

```nix
${optionalString cdnEnabled ''
  test -s "$CREDENTIALS_DIRECTORY/cdn-decryption" || { echo "missing CDN VLESS credential" >&2; exit 1; }
''}
# Add to the existing jq arguments immediately before its filter:
--rawfile decryption ${if cdnEnabled then ''"$CREDENTIALS_DIRECTORY/cdn-decryption"'' else "/dev/null"} \
```

Add a **first** tag-specific branch to the existing jq filter before the REALITY/Hysteria branches; retain their existing `elif`/`else` bodies:

```jq
if .tag == "vless-cdn-xhttp-in" then
  .settings.decryption = ($decryption | rtrimstr("\n"))
elif (.streamSettings.security // "") == "reality" then
  .streamSettings.realitySettings.privateKey = $privateKey
```

Retain the existing `xray run -test -format json` before `exec xray run -format json`. Since Xray's VLESS parser may echo an invalid `decryption` string in a validation error, replace the existing test invocation on **Veles only** with a guarded command that hides its stdout/stderr from journald yet fails and reports a static message:

```nix
${if cdnEnabled then ''
  if ! xray run -test -format json -config "$configFile" >/dev/null 2>&1; then
    echo "Xray configuration validation failed; diagnostics suppressed to protect VLESS credential" >&2
    exit 1
  fi
'' else ''
  xray run -test -format json -config "$configFile"
''}
```

Keep the production `exec xray run -format json -config "$configFile"` unchanged. Missing/invalid credentials must never make the sentinel fall back to `"none"`; check the nonempty file before rendering and rely on the guarded binary test for invalid content. Buyan and NixPi must acquire no new credentials or changed startup logging.

- [ ] **Step 5: Green and negative evaluation.** Run `bash roles/network/xray/tests/reverse.sh "path:$(pwd -P)"`, then `make check` (from the dummy-secrets checkout). Add an `extendModules` disabled-CDN variant and assert no `vless-cdn-xhttp-in` and no `cdn-decryption:` credential when `roles.xray.relay.ingress.vless.cdnXhttp.enable = lib.mkForce false;`. Also assert the forward-mode variant routes the new tag to `forward-balancer` while preserving the reverse portal for Buyan. Run `nixfmt` on the three Nix files and `git diff --check`. Never run the store-template JSON directly through `xray -test`: its intentionally invalid sentinel is replaced only at service startup after the human installs the real credential.

### Task 2: Add one Nginx HTTPS origin, static probe page and documentation

**Files:** Modify `roles/network/xray/relay.nix`, `roles/network/xray/default.nix`, `roles/network/xray/tests/reverse.sh`, `docs/proxy.md`; create `docs/veles-timeweb-cdn-deployment.md`.

**Interfaces:** Consume the Task 1 `cdnXhttp` options and `vless-cdn-xhttp-in`. Produce an origin SNI-router entry `{ sni = cdnCfg.originDomain; backend = "127.0.0.1:9443"; }` appended **after** existing REALITY entries; one Nginx vhost named by `originDomain`, with HTTP/80 and HTTPS on `127.0.0.1:9443` plus `proxyProtocol = true`. Use built-in `enableACME` and NixOS's automatic nginx reload. A successful XHTTP request stays on `/vl-cdn` and its session subpaths; invalid XHTTP 400/401/403/404 becomes the same site-style 404. No new public TCP listener other than the existing 80/443.

- [ ] **Step 1: Write failing origin tests** in `reverse.sh`: check the SNI-router entries equal the prior REALITY entries **followed by** `{ "sni": "sunny-bee-on-the-flower.net.by", "backend": "127.0.0.1:9443", "proxyProtocol": true }`; assert `roles.sni-router.defaultBackend` stays `null`, while the first entry (and therefore the effective fallback in `roles/network/sni-router.nix`) remains the previous REALITY backend. Evaluate the origin vhost with a `nix eval --impure --json --expr` using `builtins.getFlake "$flake"` and assert its two `listen` entries (HTTP/80 public, HTTPS loopback/9443/`proxyProtocol = true`), `enableACME = true`, one `/vl-cdn` proxy to 9013 with no trailing slash, no proxy caching/buffering and the `proxy_intercept_errors`/error-page handling. Check `security.acme.certs."sunny-bee-on-the-flower.net.by".reloadServices` includes `"nginx.service"` and its `dnsProvider` is `null`. Assert there is no Nginx HTTP `listen` on public 443. Add a disabled-CDN `extendModules` check for absence of the new vhost and origin SNI while preserving the old three entries. Assert `contains("no-store")` for each of the vhost's `"= /"`, `"/"`, `"@probe_404"`, `"= /vl-cdn"` and `"^~ /vl-cdn/"` location `extraConfig` strings, not just for the proxy locations. The existing daemon's stream still listens on public 443 and emits PROXY protocol; the new HTTP TLS listener must consume it.

- [ ] **Step 2: Confirm red** with `bash roles/network/xray/tests/reverse.sh "path:$(pwd -P)"`. Expect missing vhost and SNI assertions, not failure of Task 1's green checks.

- [ ] **Step 3: Append the origin SNI** in `roles/network/xray/default.nix` after the unchanged REALITY entries, gated on Task 1's `cdnEnabled`:

```nix
sniEntries =
  map (inbound: {
    sni = head inbound.streamSettings.realitySettings.serverNames;
    backend = "127.0.0.1:${toString inbound.port}";
  }) (filter (inbound: (inbound.protocol or "") == "vless" && (inbound.streamSettings.security or "") == "reality") activeTemplate.inbounds)
  ++ optional cdnEnabled {
    sni = relayCfg.ingress.vless.cdnXhttp.originDomain;
    backend = "127.0.0.1:9443";
  };
```

The SNI-router already sends PROXY to all backends; leave `roles/network/sni-router.nix` untouched. Keep the existing first/effective fallback backend unchanged and leave the `defaultBackend` option `null`; the appended entry must not become the default.

- [ ] **Step 4: Add HTTP-01, loopback HTTPS and static routes** under `mkIf cdnEnabled` in the *relay* role. Extend the role function arguments with `pkgs` only if needed; a minimal `return 200` HTML page avoids an asset/dependency. Set `security.acme.acceptTerms = true; security.acme.defaults.email = "stepan@uspenskiy.su";`. The vhost skeleton uses explicit listeners so `enableACME` cannot take over public 443:

```nix
services.nginx.virtualHosts.${cdnCfg.originDomain} = {
  enableACME = true;
  listen = [
    { addr = "0.0.0.0"; port = 80; }
    { addr = "127.0.0.1"; port = 9443; ssl = true; proxyProtocol = true; }
  ];
  locations."= /".extraConfig = ''
    default_type text/html;
    add_header Cache-Control "private, no-store" always;
    return 200 '<!doctype html><html lang="en"><meta charset="utf-8"><title>Sunny Bee</title><h1>Sunny Bee</h1></html>';
  '';
  locations."/".extraConfig = ''
    default_type text/html;
    add_header Cache-Control "private, no-store" always;
    return 404 '<!doctype html><html lang="en"><title>Not Found</title><h1>Not Found</h1></html>';
  '';
  locations."@probe_404".extraConfig = ''
    default_type text/html;
    add_header Cache-Control "private, no-store" always;
    return 404 '<!doctype html><html lang="en"><title>Not Found</title><h1>Not Found</h1></html>';
  '';
};
```

NixOS's Nginx `enableACME` inserts the HTTP-01 challenge location and sets `reloadServices = [ "nginx.service" ]`; do not enable `roles.letsencrypt`/Cloudflare DNS-01. The existing `common/server.nix` already opens TCP/80 when Nginx is enabled. Add two locations, `"= /vl-cdn"` and `"^~ /vl-cdn/"` (using the configured `cdnCfg.path`), with identical proxy options. In each, set `proxyPass = "http://127.0.0.1:9013"` **without a URI suffix** so Xray sees the complete path, and `extraConfig` including:

```nginx
proxy_http_version 1.1;
proxy_set_header Host $host;
proxy_set_header Connection "";
proxy_buffering off;
proxy_request_buffering off;
proxy_cache off;
proxy_read_timeout 3600s;
proxy_send_timeout 3600s;
send_timeout 3600s;
gzip off;
proxy_intercept_errors on;
error_page 400 401 403 404 = @probe_404;
add_header Cache-Control "private, no-store" always;
```

Use a small local `let` binding for the identical location attrsets; attach it to both path forms with `locations."= ${cdnCfg.path}" = cdnProxyLocation; locations."^~ ${cdnCfg.path}/" = cdnProxyLocation;`. These keys must be evaluated by Nix as dynamic attr names and must not match `/vl-cdn-other`. No generic module or preset. Confirm the NixOS generated Nginx configuration contains no extra public 443 HTTP `listen`; keep the common 443 **stream** route and the existing REALITY backends. If a status-code response from Xray is used by the client, stop and adjust the error interception only after a real-client test, not by weakening the encrypted inbound.

- [ ] **Step 5: Update human-facing docs.** In `docs/proxy.md`, add the optional Timeweb-issued edge → origin Nginx → encrypted VLESS/XHTTP → existing reverse balancer path; retain the not-deployed warning and NixPi/Buyan direct paths. In new `docs/veles-timeweb-cdn-deployment.md`, give the operator these exact setup and go/no-go steps, without credentials or fake success claims:

```text
Timeweb DNS: delegate sunny-bee-on-the-flower.net.by; apex A → Veles IPv4; no AAAA while IPv6 disabled.
Timeweb CDN: origin sunny-bee-on-the-flower.net.by over HTTPS; client hostname is issued *.cdn.twcstorage.ru.
CDN controls: caching/browser caching/always online/HTTP3/large-file slicing off where available; honor origin no-store; no custom alias/edge cert.
Client trial: use existing ordinary Veles UUID; port 443; address and TLS SNI = issued hostname; VLESS encryption = paired client value; XHTTP path /vl-cdn; mode packet-up; uplinkHTTPMethod GET; verify certificate.
Pre-activation: record previous Veles generation, ensure root-only decryption file is installed, DNS propagated, TCP/80 available, and Timeweb origin-pull uses plain HTTPS without adding its own PROXY header. Do not activate Xray while file absent.
Live: build, test and switch Veles only with operator approval; check ACME certificate, nginx reload, nginx -t and Xray rendered-config -test without revealing keys; test static root/404, invalid path, authorized encrypted TCP up/down, idle recovery, UDP, uncached edge behavior, Buyan egress and preserved direct routes. Watch fail2ban's Nginx jails for banned edge IPs during the sustained trials: an edge ban is a stop condition.
Recovery: restore previous known-good Veles generation and recheck direct routes if any gate fails; do not change Buyan/NixPi or advertise the CDN endpoint. For private Xray startup diagnosis, use a root-only interactive session and a controlled redacted copy of diagnostics; never send an unredacted -test failure to journald or a PR.
```

The docs must state the origin A record still reveals Veles's IP, and a static page or an HTTP status is not proof of CDN-compatible proxying.

- [ ] **Step 6: Green/failure checks.** Run the updated Xray test (including disabled-CDN and manual-forward variants), `make check`, `nixfmt` on changed Nix files, `git diff --check` and inspect `git status --short`. Do not run `make setup-dummy-secrets` on the real checkout. No keypair, DNS mutation, CDN change, `nixos-rebuild`, commit or push is part of this task. An offline Nginx/vhost evaluation does not prove that Timeweb relays the streaming traffic.

### Task 3: Human-owned final keypair handoff and separate deployment gate

**Files:** Human-only updates to tracked `secrets/unlocked/spec.txt` (filename/mode mapping, no key contents) and the encrypted-file secret flow; no implementation-agent edits to secrets. Follow `docs/veles-timeweb-cdn-deployment.md` after Tasks 1–2 have been reviewed.

**Interfaces:** Produces an installed root-readable-only `/etc/nixos/secrets/vlessenc-decryption-key` and a private paired client encryption value. The Xray unit in Task 1 consumes only the server file through `LoadCredential`. This is the **last implementation/handoff step**; live deployment/testing follows it and requires separate explicit operator approval.

- [ ] **Step 1 (human only):** On a trusted machine with the actual deployed Xray version, run `xray vlessenc` privately and store the returned **server decryption** and **client encryption** values separately in the operator's secret manager. Do not run it in a captured chat/session, paste its output into a PR or put either value in a Nix expression. The implementation agent must not run this command even with dummy keys.
- [ ] **Step 2 (human only):** Put only the server value (optionally followed by one newline) into the normal encrypted file-secret workflow; the non-secret mapping `veles:vlessenc-decryption-key:0400:root:root` is already in the tracked `secrets/unlocked/spec.txt` (commit the mapping only if explicitly requested). Install to `/etc/nixos/secrets/vlessenc-decryption-key` via the existing `make install-secrets` process on Veles; verify existence, ownership and mode without displaying contents. Never stage plaintext secret material; encrypted archive management remains a human action.
- [ ] **Step 3 (human only, separate deployment approval):** Record previous Veles generation, verify origin A/no invalid AAAA and ACME prerequisites, build Veles, run a controlled `nixos-rebuild test --flake 'path:.#veles'`, then use the operator-held client profile for real CDN tests. Require the Xray startup `-test` guard and service to succeed; probe the static page and invalid XHTTP path through both origin and CDN; prove actual encrypted TCP uploads/downloads, UDP, Buyan egress, bridge health and unbroken direct Veles/NixPi paths. During the sustained and invalid-path probes, check each enabled Nginx fail2ban jail and Nginx upstream errors; **any Timeweb edge IP banned is a stop condition**. Do not blanket-whitelist unknown CDN IP ranges or disable the jails: investigate a vhost-scoped error-log/jail exclusion and re-test it before cutover. Only after all gates pass run `nixos-rebuild switch --flake 'path:.#veles'`. If a gate fails, restore the known-good generation and check the direct paths. Validate ACME renew/reload under operator supervision. Do not infer full proxy success from status codes or a successful offline flake check.

## Self-review checks

- Tasks 1–2 cover the spec's additive encrypted inbound, existing user reuse/Buyan exclusion, fail-closed routing, Nginx one-instance HTTPS/SNI/PROXY topology, built-in HTTP-01 ACME, static page, probe 404 and no-buffer/no-store behavior. Task 3 covers the human-only final keypair step, a no-double-PROXY prerequisite, fail2ban edge-ban stop condition and a separately gated live test/rollback. Timeweb's GET limitation is client-side; no fake server preset or NixPi cutover.
- No task requires producing actual encryption material, touching Cloudflare DNS, assuming reverse relay already deployed, or treating a generated runtime-invalid template as binary-testable before secret injection. No commits are scheduled without user instruction.
