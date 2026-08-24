# Xray-carried DoT Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route CoreDNS’s Cloudflare DoT fallback through the existing nixpi Xray/VLESS client while preserving direct DoT, Google DoT, and plaintext DNS fallback in order.

**Architecture:** `roles.xray.client` gains a generic list of fixed-destination TCP tunnel listeners. Each Xray `tunnel` inbound is routed through the existing `proxy-balancer`. CoreDNS keeps TLS ownership and verifies Cloudflare’s certificate; it tries direct Cloudflare endpoints first, then its local Xray-carried Cloudflare endpoint. The outer CoreDNS forwarder explicitly fails over on nested `SERVFAIL` and `REFUSED` responses.

**Tech Stack:** NixOS modules, Xray `tunnel` inbound protocol, existing VLESS/Reality transports, CoreDNS `forward` plugin, Nix flake evaluation, `nixfmt`.

## Global Constraints

- Public API: `roles.xray.client.tunnels = [ { listen = "ADDRESS:PORT"; target = "ADDRESS:PORT"; } ];`, with an empty default.
- A tunnel binds exactly to `listen`; it can use loopback or a LAN address. Do not add or change firewall rules.
- Tunnels carry TCP only and always route through `proxy-balancer`; they do not alter SOCKS, HTTP proxy, VLESS transport, or direct-outbound behavior.
- Configure nixpi’s initial tunnel as `127.0.0.1:5053` to `1.1.1.1:853`.
- Keep `tls_servername cloudflare-dns.com`; CoreDNS must perform the DoT handshake and certificate verification through the tunnel.
- CoreDNS priority is direct Cloudflare DoT, tunneled Cloudflare DoT, direct Google DoT, then plaintext fallback.
- Preserve `failfast_all_unhealthy_upstreams`; add `failover SERVFAIL REFUSED` only to the outer port-53 forwarder.
- Do not place secrets in source files, plan output, test assertions, or logs.

---

## File Structure

- Modify `roles/network/xray/client.nix`: define, parse, validate, and render generic Xray client tunnel listeners and route them through the existing balancer.
- Modify `machines/nixpi/default.nix`: declare the initial loopback Cloudflare TCP tunnel in the existing Xray client configuration.
- Modify `roles/router/dns.nix`: add the tunneled Cloudflare DoT endpoint and configure outer CoreDNS response-code failover.

## Task 1: Add generic Xray client TCP tunnels and configure nixpi

**Files:**
- Modify: `roles/network/xray/client.nix:15-90` (endpoint helpers, inbounds, routing)
- Modify: `roles/network/xray/client.nix:92-165` (public option schema and assertions)
- Modify: `machines/nixpi/default.nix:100-146` (nixpi Xray client configuration)

**Interfaces:**
- Consumes: `roles.xray.client`’s existing `proxy-balancer`, VLESS outbounds, `port`, and optional HTTP inbound.
- Produces: `roles.xray.client.tunnels :: listOf { listen :: string; target :: string; }`.
- Produces: one Xray inbound tagged `tunnel-<zero-based-index>-in` per configured tunnel, using protocol `tunnel` and `settings = { allowedNetwork = "tcp"; rewriteAddress; rewritePort; followRedirect = false; }`.
- Produces: a `routing.rules` entry (or extension of the existing client rule) that sends every SOCKS, HTTP, and tunnel inbound tag to `proxy-balancer`.

- [ ] **Step 1: Add the nixpi consumer configuration first, to make the missing public option fail evaluation**

  In `machines/nixpi/default.nix`, insert this inside `roles.xray.client`, adjacent to `port`, `openFirewall`, and `http`:

  ```nix
  tunnels = [
    {
      listen = "127.0.0.1:5053";
      target = "1.1.1.1:853";
    }
  ];
  ```

  Run:

  ```bash
  make setup-dummy-secrets
  nix eval .#nixosConfigurations.nixpi.config.system.build.toplevel
  ```

  Expected: evaluation fails because `roles.xray.client.tunnels` is not yet a defined option. Do not commit this intentionally failing intermediate state.

- [ ] **Step 2: Define endpoint parsing and tunnel-derived Xray configuration in `roles/network/xray/client.nix`**

  In the module’s `let` block, add a parser that requires a non-empty address followed by a decimal port, accepts either bare or bracketed IPv6 addresses, and rejects ports outside `1..65535` with an option-specific error. Keep parsing local to this module.

  ```nix
  parseEndpoint = optionName: endpoint:
    let
      matches = builtins.match "^(.+):([0-9]+)$" endpoint;
    in
    if matches == null then
      throw "roles.xray.client.${optionName} must be ADDRESS:PORT"
    else
      let
        rawAddress = elemAt matches 0;
        port = toInt (elemAt matches 1);
        hasOpeningBracket = hasPrefix "[" rawAddress;
        hasClosingBracket = hasSuffix "]" rawAddress;
        address =
          if hasOpeningBracket then
            removePrefix "[" (removeSuffix "]" rawAddress)
          else
            rawAddress;
      in
      if hasOpeningBracket != hasClosingBracket || address == "" then
        throw "roles.xray.client.${optionName} must have a non-empty address with paired IPv6 brackets"
      else if port < 1 || port > 65535 then
        throw "roles.xray.client.${optionName} port must be in the range 1..65535"
      else
        { inherit address port; };

  parsedTunnels = imap0 (
    index: tunnel: {
      inherit index;
      listen = parseEndpoint "tunnels[${toString index}].listen" tunnel.listen;
      target = parseEndpoint "tunnels[${toString index}].target" tunnel.target;
    }
  ) cfg.tunnels;

  tunnelInbounds = map (
    tunnel: {
      listen = tunnel.listen.address;
      port = tunnel.listen.port;
      protocol = "tunnel";
      tag = "tunnel-${toString tunnel.index}-in";
      settings = {
        allowedNetwork = "tcp";
        rewriteAddress = tunnel.target.address;
        rewritePort = tunnel.target.port;
        followRedirect = false;
      };
    }
  ) parsedTunnels;

  proxyInboundTags =
    [ "socks-in" ]
    ++ optional cfg.http.enable "http-in"
    ++ map (tunnel: "tunnel-${toString tunnel.index}-in") parsedTunnels;
  ```

  Change the `xrayConfig.inbounds` composition to append `tunnelInbounds` after the current SOCKS and optional HTTP inbounds. Change the existing client routing rule to use `inboundTag = proxyInboundTags`; retain `balancerTag = "proxy-balancer"`.

- [ ] **Step 3: Add the public option and collision assertions**

  Add the following option directly under `roles.xray.client`, alongside `port` and `http`:

  ```nix
  tunnels = mkOption {
    type = types.listOf (
      types.submodule {
        options = {
          listen = mkOption {
            type = types.str;
            example = "127.0.0.1:5053";
            description = "Local address and TCP port for the Xray tunnel listener";
          };
          target = mkOption {
            type = types.str;
            example = "1.1.1.1:853";
            description = "Fixed remote address and TCP port carried through Xray";
          };
        };
      }
    );
    default = [ ];
    description = "Fixed-destination TCP tunnels routed through the Xray proxy balancer";
  };
  ```

  Extend the existing `assertions` list with checks that:

  ```nix
  {
    assertion =
      length (unique (map (tunnel: tunnel.listen) parsedTunnels))
      == length parsedTunnels;
    message = "roles.xray.client.tunnels must not contain duplicate listen endpoints";
  }
  {
    assertion = all (
      tunnel:
      tunnel.listen.port != cfg.port
      && (!cfg.http.enable || tunnel.listen.port != cfg.http.port)
    ) parsedTunnels;
    message = "roles.xray.client.tunnels must not reuse the SOCKS or HTTP proxy listen port";
  }
  ```

  These checks are in addition to parser failures for malformed endpoints or invalid port ranges. The collision check is port-based because the existing SOCKS and HTTP inbounds bind `0.0.0.0`.

- [ ] **Step 4: Format and verify the generated Xray JSON before committing**

  Run:

  ```bash
  nixfmt roles/network/xray/client.nix machines/nixpi/default.nix
  nix eval --json .#nixosConfigurations.nixpi.config.services.xray.settings.inbounds \
    | jq -e '
        any(
          .[];
          .tag == "tunnel-0-in"
          and .protocol == "tunnel"
          and .listen == "127.0.0.1"
          and .port == 5053
          and .settings.allowedNetwork == "tcp"
          and .settings.rewriteAddress == "1.1.1.1"
          and .settings.rewritePort == 853
          and .settings.followRedirect == false
        )
      '
  nix eval --json .#nixosConfigurations.nixpi.config.services.xray.settings.routing.rules \
    | jq -e 'any(.[]; .balancerTag == "proxy-balancer" and (.inboundTag | index("tunnel-0-in")))'
  ```

  Expected: both `jq -e` commands exit `0`. The evaluated values contain only inbound/routing metadata and do not print VLESS credentials.

- [ ] **Step 5: Commit the self-contained Xray tunnel API and nixpi declaration**

  ```bash
  git add roles/network/xray/client.nix machines/nixpi/default.nix
  git commit -m "feat(xray): add TCP tunnel client inbounds"
  ```

## Task 2: Use the Xray tunnel as CoreDNS’s Cloudflare DoT fallback

**Files:**
- Modify: `roles/router/dns.nix:37-97`

**Interfaces:**
- Consumes: the `127.0.0.1:5053` Xray TCP listener produced by Task 1.
- Produces: a Cloudflare DoT `forward` block whose target order is `1.1.1.1`, `1.0.0.1`, then `127.0.0.1:5053`.
- Produces: outer CoreDNS behavior that retries the next local provider listener on `SERVFAIL` or `REFUSED`.

- [ ] **Step 1: Establish configuration-level regression checks that fail before editing the Corefile**

  Run:

  ```bash
  nix eval --raw .#nixosConfigurations.nixpi.config.services.coredns.config \
    | grep -F 'forward . tls://1.1.1.1 tls://1.0.0.1 tls://127.0.0.1:5053 {'
  nix eval --raw .#nixosConfigurations.nixpi.config.services.coredns.config \
    | grep -F 'failover SERVFAIL REFUSED'
  ```

  Expected: both commands exit non-zero because neither the tunnel endpoint nor response-code failover exists yet. Do not treat those expected failures as a completed validation.

- [ ] **Step 2: Configure the ordered Cloudflare endpoint chain and outer response-code failover**

  In the main `forward . 127.0.0.1:9055 127.0.0.1:9057 127.0.0.1:9058` block, retain `policy sequential`, `health_check`, `max_fails`, and `failfast_all_unhealthy_upstreams`; add:

  ```caddyfile
  failover SERVFAIL REFUSED
  ```

  In the `.:9055` Cloudflare block, replace the target list with this exact ordered list and retain the existing TLS settings:

  ```caddyfile
  forward . tls://1.1.1.1 tls://1.0.0.1 tls://127.0.0.1:5053 {
    tls_servername cloudflare-dns.com
    health_check 5s
    max_fails 2
    policy sequential
  }
  ```

  Do not add the local Xray listener to the Google block and do not change the plaintext `:9058` block.

- [ ] **Step 3: Verify the rendered CoreDNS configuration and full flake evaluation**

  Run:

  ```bash
  nixfmt roles/router/dns.nix
  nix eval --raw .#nixosConfigurations.nixpi.config.services.coredns.config \
    | grep -F 'forward . tls://1.1.1.1 tls://1.0.0.1 tls://127.0.0.1:5053 {'
  nix eval --raw .#nixosConfigurations.nixpi.config.services.coredns.config \
    | grep -F 'failover SERVFAIL REFUSED'
  make check
  ```

  Expected: both `grep` commands print their matching lines and exit `0`; `make check` completes successfully for every configured system.

- [ ] **Step 4: Commit the CoreDNS fallback behavior**

  ```bash
  git add roles/router/dns.nix
  git commit -m "feat(dns): tunnel Cloudflare DoT through Xray fallback"
  ```

## Task 3: Deploy on nixpi and verify the live data path

**Files:**
- Modify: none

**Interfaces:**
- Consumes: the committed NixOS configuration from Tasks 1 and 2.
- Produces: evidence that Xray accepts local TLS, carries it through VLESS, and CoreDNS remains available on port 53.

- [ ] **Step 1: Build and switch the nixpi configuration from the nixpi checkout**

  Run on nixpi:

  ```bash
  sudo nixos-rebuild switch --flake 'path:.#nixpi'
  systemctl is-active xray coredns
  ```

  Expected: `nixos-rebuild` completes successfully and both status checks print `active`.

- [ ] **Step 2: Verify the local tunnel carries a Cloudflare-authenticated TLS handshake**

  Run on nixpi:

  ```bash
  openssl s_client \
    -connect 127.0.0.1:5053 \
    -servername cloudflare-dns.com \
    -verify_hostname cloudflare-dns.com \
    -verify_return_error \
    </dev/null
  ```

  Expected: the TLS handshake succeeds and certificate verification reports `Verify return code: 0 (ok)`. This proves Xray relayed the TCP stream while Cloudflare terminated TLS.

- [ ] **Step 3: Verify normal local resolution and capture diagnostics if it fails**

  Run on nixpi:

  ```bash
  dig @127.0.0.1 -p 53 example.com A +short
  journalctl -u coredns -u xray --since '10 minutes ago' --no-pager
  ```

  Expected: `dig` returns one or more IPv4 addresses and both services remain active. If resolution fails, preserve the two service logs before changing provider, Xray, or firewall configuration.

- [ ] **Step 4: Record the deployment result without changing fallback policy ad hoc**

  Record whether direct DoT, tunneled DoT, and normal port-53 resolution succeeded. Leave `failfast_all_unhealthy_upstreams`, the VLESS transport set, and firewall policy unchanged; any later live fallback simulation is a separate maintenance operation.

## Final Verification

- [ ] Run the repository formatter check:

  ```bash
  nix develop --command nixfmt --check $(find . -name '*.nix' | tr '\n' ' ')
  ```

  Expected: exit `0`.

- [ ] Confirm the working tree has only the two intended implementation commits (plus this planning documentation if it remains uncommitted during implementation):

  ```bash
  git status --short
  git log --oneline -3
  ```

  Expected: no untracked secrets, no unformatted Nix files, and commits named `feat(xray): add TCP tunnel client inbounds` and `feat(dns): tunnel Cloudflare DoT through Xray fallback`.
