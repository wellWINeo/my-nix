# RSSHub on Mokosh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy a browser-free, localhost-only RSSHub service on `mokosh` for Miniflux, with the `anthropic/research` route as the first smoke test.

**Architecture:** Extend the existing `roles.rss` role with a `roles.rss.hub.enable` submodule in `roles/reading/rss/rsshub.nix`. Use the pinned nixpkgs `services.rsshub` module and package, bind it to `127.0.0.1:1200`, and use an explicit in-memory cache with Redis disabled. Miniflux will consume `http://127.0.0.1:1200/anthropic/research`; no public proxy or browser service is added.

**Tech Stack:** Nix flakes, NixOS modules, systemd, nixpkgs `services.rsshub`, RSSHub `0-unstable-2026-05-14`, Miniflux, `nixfmt`, `nix flake check`, and `curl`.

## Global Constraints

- RSSHub must be reachable by Miniflux on the same host, but it must not be reachable from the public network.
- Place the module in `roles/reading/rss/rsshub.nix`.
- Expose the enable option as `roles.rss.hub.enable`.
- Use the nixpkgs `services.rsshub` module and package.
- Listen on `127.0.0.1:1200` only.
- Use RSSHub's in-memory cache and explicitly disable Redis.
- Do not add a public endpoint, DNS record, Nginx virtual host, ACME certificate, or firewall rule.
- Do not add Chromium, browserless, Puppeteer, or Playwright deployment.
- Do not add a custom RSSHub package, flake input, overlay, or GitHub Actions build.
- Do not make declarative Miniflux feed or database changes.
- Do not change RSSHub routes or upstream source.
- Do not add an automated test framework.
- Do not commit changes unless explicitly requested.

---

## File Structure

| File | Action | Responsibility |
| --- | --- | --- |
| `roles/reading/rss/rsshub.nix` | create | Declare `roles.rss.hub.enable` and configure the native RSSHub service. |
| `roles/reading/rss/default.nix` | modify | Import the RSSHub role module. |
| `machines/mokosh/default.nix` | modify | Enable `roles.rss.hub` in the existing RSS role configuration. |
| `README.md` | modify | Document RSSHub in the RSS role and its localhost-only boundary. |
| `docs/superpowers/specs/2026-07-26-rsshub-mokosh-design.md` | modify | Record the approved design status. |
| `docs/superpowers/plans/2026-07-26-rsshub-mokosh.md` | create | Record this implementation plan. |

No changes are planned for `flake.nix`, `flake.lock`, `common/cache.nix`,
`roles/reading/rss/miniflux.nix`, or the Miniflux database.

## Task 1: Add the RSSHub Role Module

**Files:**
- Create: `roles/reading/rss/rsshub.nix`
- Modify: `roles/reading/rss/default.nix`

**Interfaces:**
- Consumes: `config.roles.rss.enable` and the nixpkgs `services.rsshub` module.
- Produces: `roles.rss.hub.enable` and a localhost-only `systemd.services.rsshub` configuration.

- [ ] **Step 1: Create the nested RSSHub role module**

Create `roles/reading/rss/rsshub.nix` with exactly this module:

```nix
{ config, lib, ... }:

with lib;

let
  cfg = config.roles.rss.hub;
in
{
  options.roles.rss.hub.enable = mkEnableOption "RSSHub";

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = config.roles.rss.enable;
        message = "roles.rss.hub requires roles.rss to be enabled";
      }
    ];

    services.rsshub = {
      enable = true;
      redis.enable = false;
      settings = {
        PORT = 1200;
        LISTEN_INADDR_ANY = false;
        CACHE_TYPE = "memory";
      };
    };
  };
}
```

- [ ] **Step 2: Import the module through the existing RSS role entry point**

Update `roles/reading/rss/default.nix` to:

```nix
{ ... }:

{
  imports = [
    ./miniflux.nix
    ./rsshub.nix
    ./summarizer/service.nix
    ./backup.nix
  ];
}
```

- [ ] **Step 3: Format both RSS role files**

Run:

```bash
nix develop --command nixfmt \
  roles/reading/rss/rsshub.nix \
  roles/reading/rss/default.nix
```

Expected: exit code `0`, with no formatting errors.

## Task 2: Enable RSSHub on Mokosh and Document the Boundary

**Files:**
- Modify: `machines/mokosh/default.nix:167-180`
- Modify: `README.md:46-49` and the RSS role documentation section

**Interfaces:**
- Consumes: the `roles.rss.hub.enable` option from Task 1.
- Produces: an enabled RSSHub service in the `mokosh` NixOS configuration and repository documentation for its private URL.

- [ ] **Step 1: Enable the nested hub in the existing `roles.rss` block**

Add `hub.enable = true;` immediately after `enable = true;` in the existing
RSS configuration. The resulting block begins:

```nix
  roles.rss = {
    enable = true;
    hub.enable = true;
    baseDomain = domainNames.secondary;
    summarizer = {
```

Keep all existing `baseDomain` and summarizer values unchanged.

- [ ] **Step 2: Update the README role inventory**

Change the RSS directory description in `README.md` from:

```text
│   │   └── rss/             #   miniflux + summarizer + backup
```

to:

```text
│   │   └── rss/             #   miniflux + RSSHub + summarizer + backup
```

- [ ] **Step 3: Document the localhost-only RSSHub behavior**

After the existing Roles System section in `README.md`, add:

```markdown
RSSHub is enabled on `mokosh` as `roles.rss.hub.enable`. It listens only on
`127.0.0.1:1200` for Miniflux and is not exposed through Nginx, DNS, or the
firewall. The initial browser-free route is
`http://127.0.0.1:1200/anthropic/research`.
```

- [ ] **Step 4: Format the machine configuration**

Run:

```bash
nix develop --command nixfmt machines/mokosh/default.nix
```

Expected: exit code `0` and no unrelated formatting changes.

## Task 3: Evaluate the Configuration and Verify Binary Substitution

**Files:**
- Test: `nixosConfigurations.mokosh`
- Test: `nixpkgs` RSSHub package output

**Interfaces:**
- Consumes: the role and machine configuration from Tasks 1 and 2.
- Produces: evidence that the service settings are correct and the locked RSSHub package is available from `cache.nixos.org`.

- [ ] **Step 1: Ensure a validation secrets file exists without replacing real secrets**

Run:

```bash
test -f secrets/secrets.json || make setup-dummy-secrets
```

Expected: `secrets/secrets.json` exists. An existing unlocked secrets file is
not modified.

- [ ] **Step 2: Evaluate the selected service settings**

Run:

```bash
nix eval --impure --json --expr '
  let
    cfg = (builtins.getFlake (toString ./.)).nixosConfigurations.mokosh.config;
  in {
    roleEnabled = cfg.roles.rss.hub.enable;
    serviceEnabled = cfg.services.rsshub.enable;
    port = cfg.services.rsshub.settings.PORT;
    listenAny = cfg.services.rsshub.settings.LISTEN_INADDR_ANY;
    cacheType = cfg.services.rsshub.settings.CACHE_TYPE;
    redisEnabled = cfg.services.rsshub.redis.enable;
    firewallExposesPort = builtins.elem 1200 cfg.networking.firewall.allowedTCPPorts;
  }
'
```

Expected values are:

```json
{
  "roleEnabled": true,
  "serviceEnabled": true,
  "port": "1200",
  "listenAny": "0",
  "cacheType": "memory",
  "redisEnabled": false,
  "firewallExposesPort": false
}
```

- [ ] **Step 3: Confirm the exact package version from the locked flake**

Run:

```bash
nix eval --raw 'path:.#nixosConfigurations.mokosh.pkgs.rsshub.version'
```

Expected:

```text
0-unstable-2026-05-14
```

- [ ] **Step 4: Confirm the exact package output is in the official binary cache**

Run:

```bash
RSSHUB_OUT=$(nix eval --raw 'path:.#nixosConfigurations.mokosh.pkgs.rsshub.outPath')
nix path-info --store https://cache.nixos.org "$RSSHUB_OUT"
```

Expected: the command prints the same `/nix/store/...-rsshub-0-unstable-2026-05-14`
path and does not build the derivation.

- [ ] **Step 5: Run the repository flake check**

Run:

```bash
make check
```

Expected: exit code `0` with no missing-option, RSSHub module, service, or
evaluation errors.

## Task 4: Deploy and Run Runtime Smoke Tests

**Files:**
- Deploy: `nixosConfigurations.mokosh`
- Runtime checks: `rsshub.service` and the loopback HTTP endpoint

**Interfaces:**
- Consumes: the evaluated configuration and cached RSSHub package from Task 3.
- Produces: a running localhost-only RSSHub service and a verified
  `anthropic/research` feed response for Miniflux.

- [ ] **Step 1: Apply the configuration on mokosh**

From the repository checkout on `mokosh`, run:

```bash
make switch
```

Expected: `nixos-rebuild` completes successfully and uses the binary cache for
the RSSHub package rather than building it locally.

- [ ] **Step 2: Confirm the RSSHub service is active**

Run on `mokosh`:

```bash
systemctl is-active --quiet rsshub.service
```

Expected: exit code `0`.

- [ ] **Step 3: Confirm the local health endpoint**

Run on `mokosh`:

```bash
curl --fail --silent --show-error http://127.0.0.1:1200/healthz
```

Expected: exit code `0` and a successful health response.

- [ ] **Step 4: Fetch the browser-free Anthropic route**

Run on `mokosh`:

```bash
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
curl --fail --silent --show-error \
  http://127.0.0.1:1200/anthropic/research \
  > "$tmp"
test -s "$tmp"
grep -Eq '<(rss|feed)([ >])' "$tmp"
```

Expected: the route returns a non-empty RSS or Atom document and no browser
service is involved.

- [ ] **Step 5: Confirm loopback-only listening**

Run on `mokosh`:

```bash
listeners=$(ss -ltnH 'sport = :1200')
printf '%s\n' "$listeners" | grep -Eq '127\.0\.0\.1:1200'
! printf '%s\n' "$listeners" | grep -Eq '0\.0\.0\.0:1200|\*:[0-9]+|\[::\]:1200'
test -z "$(systemctl list-unit-files 'browserless*' --no-legend)"
```

Expected: port `1200` is bound to loopback only and no browserless service was
introduced.

- [ ] **Step 6: Add the route to Miniflux manually and refresh it**

In the existing Miniflux instance, add this feed URL:

```text
http://127.0.0.1:1200/anthropic/research
```

Trigger a feed refresh and confirm that Miniflux imports Anthropic Research
entries. This is intentionally application data rather than a Nix-managed
database mutation.

## Task 5: Final Diff and Validation Review

**Files:**
- Review: all files changed by Tasks 1 and 2

**Interfaces:**
- Consumes: the completed role, machine, documentation, and validation work.
- Produces: a clean final change set limited to the approved RSSHub deployment.

- [ ] **Step 1: Check whitespace errors**

Run:

```bash
git diff --check
```

Expected: no output and exit code `0`.

- [ ] **Step 2: Confirm no dependency or lockfile changes**

Run:

```bash
git status --short
```

Expected changed paths are limited to:

```text
README.md
machines/mokosh/default.nix
roles/reading/rss/default.nix
roles/reading/rss/rsshub.nix
docs/superpowers/specs/2026-07-26-rsshub-mokosh-design.md
docs/superpowers/plans/2026-07-26-rsshub-mokosh.md
```

There must be no `flake.lock`, secret, generated artifact, or unrelated role
change.

- [ ] **Step 3: Repeat the full flake check after the final diff review**

Run:

```bash
make check
```

Expected: exit code `0`.

## Self-Review

- **Spec coverage:** Tasks 1 and 2 implement the role placement and `mokosh`
  enablement; Task 3 covers explicit loopback, memory cache, Redis disablement,
  and binary substitution; Task 4 covers service operation, the browser-free
  route, and exposure checks; Task 5 covers scope and final validation.
- **Placeholder scan:** No step depends on an unspecified value or contains a
  `TBD`, `TODO`, or deferred implementation instruction.
- **Type consistency:** `roles.rss.hub.enable` is declared in Task 1 and
  enabled in Task 2; `services.rsshub.settings` uses the nixpkgs option types
  for `PORT` and `LISTEN_INADDR_ANY`; Task 3 evaluates those same names.
- **Scope check:** The plan does not add Docker, Redis, browser dependencies,
  public routing, a custom package, a flake input, or Miniflux database code.
- **Validation check:** The plan verifies both declarative configuration and
  the deployed service, including the route response and loopback binding.
