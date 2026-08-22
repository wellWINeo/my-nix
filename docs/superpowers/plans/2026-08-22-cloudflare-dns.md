# Declarative Cloudflare DNS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Manage authoritative Cloudflare A, CNAME, MX, and TXT records from this NixOS-configuration flake, with separate local and GitHub Actions preview, drift-check, and approved-apply workflows.

**Architecture:** `dns/zones.nix` is the non-secret Nix source of truth. A pure Nix renderer validates it and produces DNSControl JSON IR; shell apps use that IR and construct a temporary credentials file only at runtime. The existing flake check validates the renderer on pull requests; a dedicated workflow checks live drift on a schedule and runs a reviewed apply only after a live manual preview.

**Tech Stack:** Nix flakes, nixpkgs `dnscontrol`, Bash, `jq`, GitHub Actions, Cloudflare API tokens.

## Global Constraints

- Initially support only `A`, `CNAME`, `MX`, and `TXT` records; reject every other type during Nix evaluation.
- A zone declaration is authoritative: omitted non-provider-managed records are deleted by DNSControl on the next successful apply.
- Every live DNSControl invocation must include `--no-populate`.
- `CLOUDFLARE_DNS_TOKEN` must never appear in Nix source, a derivation, Git, command arguments, logs, or artifacts.
- The wrapper must remove its mode-`0600` temporary credential file on every exit path and disable `CLOUDFLAREAPI_DEBUG`.
- Use one Cloudflare token with only `Zone:Read` and `DNS:Edit`, scoped to the managed zones. Store the same token in both GitHub Environments named `cloudflare-dns-drift` and `cloudflare-dns-apply`.
- Restrict both environments to the protected default branch; only `cloudflare-dns-apply` has required reviewers.
- Pull-request CI is secret-free. Scheduled drift and manually dispatched previews use `cloudflare-dns-drift`; manually approved applies use `cloudflare-dns-apply`.
- Preserve the flake's `x86_64-linux`, `aarch64-linux`, and `aarch64-darwin` evaluation set. Run `make setup-dummy-secrets` before `make check`, and format all changed Nix files with `make fmt`.

---

## File Structure

- `dns/zones.nix` — versioned, non-secret zone and record declarations. It starts empty and is populated only from a reviewed Cloudflare inventory.
- `dns/lib.nix` — pure record-schema validation and transformation from the source model to DNSControl IR.
- `dns/default.nix` — builds the store-safe JSON IR from `zones.nix`.
- `dns/apps.nix` — produces the three runtime-only DNSControl applications.
- `dns/tests/zones.nix` — representative non-production fixture covering every initially supported record type.
- `dns/tests/default.nix` — validates renderer rejection cases, IR shape, and DNSControl offline IR validation.
- `docs/dns.md` — record schema, token setup, local workflow, adoption procedure, CI controls, and rollback procedure.
- `.github/workflows/check.yml` — extends the existing secret-free PR/main validation with the offline DNS renderer check.
- `.github/workflows/dns.yml` — scheduled drift check, manual preview, and reviewer-gated apply.
- `flake.nix` — exposes the IR and apps, and adds the renderer test to flake checks.
- `README.md` — links operators to the DNS guide.

## Record Source Interface

`dns/zones.nix` uses this exact Nix model:

```nix
{
  "example.com" = {
    records = [
      {
        type = "A";
        name = "@";
        address = "192.0.2.10";
        proxied = true;
        ttl = "auto";
      }
      {
        type = "CNAME";
        name = "www";
        target = "origin.example.net.";
        proxied = true;
        ttl = "auto";
      }
      {
        type = "MX";
        name = "@";
        priority = 10;
        exchange = "mail.example.com.";
        ttl = 3600;
      }
      {
        type = "TXT";
        name = "@";
        text = "v=spf1 include:_spf.example.net -all";
        ttl = 3600;
      }
    ];
  };
}
```

`name` is relative to its enclosing zone and `@` is the apex. `CNAME.target` and `MX.exchange` are required to be absolute DNS names ending in `.`. `ttl = "auto"` renders to Cloudflare's auto-TTL value `1`; an integer TTL must be at least `60`. `proxied` is accepted only on A and CNAME records and renders to DNSControl `cloudflare_proxy` metadata.

---

### Task 1: Build and test the pure Nix source model and IR renderer

**Files:**
- Create: `dns/zones.nix`
- Create: `dns/lib.nix`
- Create: `dns/default.nix`
- Create: `dns/tests/zones.nix`
- Create: `dns/tests/default.nix`
- Modify: `flake.nix:33-153`

**Interfaces:**
- Consumes: a zone attrset in the `Record Source Interface` format.
- Produces: `render :: AttrSet -> DNSControlIR`, where `DNSControlIR` has `registrars`, `dns_providers`, and `domains` compatible with `dnscontrol check --ir`.
- Produces: `dns.ir`, a JSON file containing no Cloudflare credential.
- Later tasks consume: `{ config, ir }` returned by `import ./dns { pkgs = ...; }`.

- [ ] **Step 1: Write the fixture source and renderer assertions before implementation**

Create `dns/tests/zones.nix`:

```nix
{
  "example.test" = {
    records = [
      {
        type = "A";
        name = "@";
        address = "192.0.2.10";
        proxied = true;
        ttl = "auto";
      }
      {
        type = "CNAME";
        name = "www";
        target = "origin.example.net.";
        proxied = false;
        ttl = 300;
      }
      {
        type = "MX";
        name = "@";
        priority = 10;
        exchange = "mail.example.test.";
        ttl = 3600;
      }
      {
        type = "TXT";
        name = "@";
        text = "v=spf1 -all";
        ttl = 3600;
      }
    ];
  };
}
```

Create `dns/tests/default.nix` with a success fixture and three required rejection cases: a CNAME target without a trailing dot, an MX record with `proxied`, and an unsupported `AAAA` record.

```nix
{ pkgs }:
let
  renderer = import ../lib.nix { inherit (pkgs) lib; };
  config = renderer.render (import ./zones.nix);
  ir = pkgs.writeText "dnscontrol-render-test.json" (builtins.toJSON config);
  mustFail = zones: !(builtins.tryEval (builtins.deepSeq (renderer.render zones) true)).success;
  invalidCname = {
    "example.test".records = [
      {
        type = "CNAME";
        name = "www";
        target = "origin.example.net";
      }
    ];
  };
  invalidMxProxy = {
    "example.test".records = [
      {
        type = "MX";
        name = "@";
        priority = 10;
        exchange = "mail.example.test.";
        proxied = true;
      }
    ];
  };
  invalidType = {
    "example.test".records = [
      {
        type = "AAAA";
        name = "@";
        address = "2001:db8::10";
      }
    ];
  };
  validationCasesPass =
    assert mustFail invalidCname;
    assert mustFail invalidMxProxy;
    assert mustFail invalidType;
    true;
in
assert validationCasesPass;
pkgs.runCommand "dns-render-test" {
  nativeBuildInputs = [
    pkgs.dnscontrol
    pkgs.jq
  ];
} ''
  set -euo pipefail

  dnscontrol check --ir ${ir} | tee "$TMPDIR/dnscontrol-check.out"
  grep -Fx 'No errors.' "$TMPDIR/dnscontrol-check.out"

  jq -e '
    .registrars == [{"name": "none", "type": "NONE"}]
    and .dns_providers == [{"name": "cloudflare", "type": "CLOUDFLAREAPI"}]
    and .domains[0].name == "example.test"
    and [.domains[0].records[].type] == ["A", "CNAME", "MX", "TXT"]
    and .domains[0].records[0].meta.cloudflare_proxy == "on"
    and .domains[0].records[1].meta.cloudflare_proxy == "off"
    and .domains[0].records[2].mxpreference == 10
    and .domains[0].records[3].target == "v=spf1 -all"
  ' ${ir} >/dev/null

  touch "$out"
''
```

Add this new top-level output in `flake.nix` beside `packages` and `devShells`:

```nix
      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgsFor.${system};
        in
        {
          dns-render = import ./dns/tests { inherit pkgs; };
        }
      );
```

- [ ] **Step 2: Run the new test and confirm it fails because the renderer does not exist**

Run:

```bash
make setup-dummy-secrets
system="$(nix eval --impure --raw --expr builtins.currentSystem)"
nix build --print-build-logs ".#checks.${system}.dns-render"
```

Expected: failure reporting that `dns/lib.nix` does not exist.

- [ ] **Step 3: Implement the schema validator and renderer**

Create `dns/lib.nix`:

```nix
{ lib }:
let
  fail = message: throw "dns: ${message}";

  require = condition: message:
    if condition then true else fail message;

  nonEmptyString = value: builtins.isString value && value != "";

  requiredString = record: field:
    if builtins.hasAttr field record && nonEmptyString record.${field} then
      record.${field}
    else
      fail "record field `${field}` must be a non-empty string";

  absoluteTarget = record: field:
    let
      value = requiredString record field;
    in
    if lib.hasSuffix "." value then
      value
    else
      fail "record field `${field}` must be an absolute DNS name ending in `.`";

  renderTtl = ttl:
    if ttl == "auto" then
      1
    else if builtins.isInt ttl && ttl >= 60 then
      ttl
    else
      fail "ttl must be `auto` or an integer of at least 60";

  renderRecord = record:
    assert require (builtins.isAttrs record) "each record must be an attrset";
    assert require (record ? type && builtins.isString record.type) "each record needs string `type`";
    assert require (lib.elem record.type [ "A" "CNAME" "MX" "TXT" ]) "unsupported record type `${record.type}`";
    assert require (record ? name && nonEmptyString record.name && !lib.hasSuffix "." record.name) "record `name` must be a non-empty relative name";
    let
      ttl = renderTtl (record.ttl or "auto");
      proxyMeta =
        if record ? proxied then
          if lib.elem record.type [ "A" "CNAME" ] && builtins.isBool record.proxied then
            {
              cloudflare_proxy = if record.proxied then "on" else "off";
            }
          else
            fail "`proxied` is a boolean allowed only on A and CNAME records"
        else
          { };
      common = {
        type = record.type;
        name = record.name;
        inherit ttl;
      } // lib.optionalAttrs (proxyMeta != { }) {
        meta = proxyMeta;
      };
    in
    if record.type == "A" then
      common // {
        target = requiredString record "address";
      }
    else if record.type == "CNAME" then
      common // {
        target = absoluteTarget record "target";
      }
    else if record.type == "MX" then
      assert require (record ? priority && builtins.isInt record.priority && record.priority >= 0 && record.priority <= 65535) "MX `priority` must be an integer from 0 through 65535";
      common // {
        target = absoluteTarget record "exchange";
        mxpreference = record.priority;
      }
    else
      common // {
        target =
          if record ? text && builtins.isString record.text then
            record.text
          else
            fail "TXT record field `text` must be a string";
      };

  renderZone = zone: spec:
    assert require (builtins.isString zone && zone != "" && !lib.hasSuffix "." zone) "zone names must be non-empty and have no trailing dot";
    assert require (builtins.isAttrs spec && spec ? records && builtins.isList spec.records) "zone `${zone}` needs a list of `records`";
    let
      records = map renderRecord spec.records;
      recordKeys = map builtins.toJSON records;
    in
    assert require (builtins.length recordKeys == builtins.length (lib.unique recordKeys)) "zone `${zone}` contains an identical duplicate record";
    {
      name = zone;
      uniquename = zone;
      registrar = "none";
      dnsProviders = {
        cloudflare = 0;
      };
      inherit records;
    };
in
{
  render = zones:
    assert require (builtins.isAttrs zones) "zones must be an attrset";
    {
      registrars = [
        {
          name = "none";
          type = "NONE";
        }
      ];
      dns_providers = [
        {
          name = "cloudflare";
          type = "CLOUDFLAREAPI";
        }
      ];
      domains = map (zone: renderZone zone zones.${zone}) (lib.sort lib.lessThan (builtins.attrNames zones));
    };
}
```

Create `dns/default.nix`:

```nix
{ pkgs }:
let
  renderer = import ./lib.nix { inherit (pkgs) lib; };
  config = renderer.render (import ./zones.nix);
in
{
  inherit config;
  ir = pkgs.writeText "dnscontrol.json" (builtins.toJSON config);
}
```

Create `dns/zones.nix` with the deliberately empty initial source:

```nix
{ }
```

- [ ] **Step 4: Re-run the renderer test and format the Nix files**

Run:

```bash
make fmt
make setup-dummy-secrets
system="$(nix eval --impure --raw --expr builtins.currentSystem)"
nix build --print-build-logs ".#checks.${system}.dns-render"
make check
```

Expected: `dnscontrol check` prints `No errors.`, Nix builds the `dns-render-test` derivation successfully, and `make check` evaluates the complete flake.

- [ ] **Step 5: Commit the tested renderer**

```bash
git add flake.nix dns/zones.nix dns/lib.nix dns/default.nix dns/tests/zones.nix dns/tests/default.nix
git commit -m "feat: render DNSControl records from Nix"
```

Expected: one commit containing only the source-model, renderer, and renderer-test files.

### Task 2: Expose safe local DNSControl applications through the flake

**Files:**
- Create: `dns/apps.nix`
- Modify: `flake.nix:14-100`

**Interfaces:**
- Consumes: `ir`, the secret-free JSON file from `dns/default.nix`.
- Produces: packages and apps named `dnscontrol-ir`, `dns-preview`, `dns-drift-check`, and `dns-apply`.
- Invocation contract: `dns-preview [ZONE]`, `dns-drift-check [ZONE]`, and `dns-apply --confirm [ZONE]`.
- Security contract: no caller argument can replace `--ir`, `--creds`, or `--no-populate`.

- [ ] **Step 1: Write the failing flake-app smoke commands**

Run these commands before adding `dns/apps.nix` or editing the flake:

```bash
nix build .#dnscontrol-ir
nix run .#dns-preview --
nix run .#dns-apply -- --confirm
```

Expected: the build and both apps fail because the attributes do not yet exist. The future preview/apply failure without `CLOUDFLARE_DNS_TOKEN` must be the exact safe failure mode, not a Cloudflare API call.

- [ ] **Step 2: Implement the shared runtime-secret wrapper**

Create `dns/apps.nix`:

```nix
{ pkgs, ir }:
let
  mkApp = name: mode:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        pkgs.coreutils
        pkgs.dnscontrol
        pkgs.jq
      ];
      text = ''
        set -euo pipefail
        unset CLOUDFLAREAPI_DEBUG

        mode=${pkgs.lib.escapeShellArg mode}
        usage() {
          case "$mode" in
            preview)
              printf '%s\n' 'usage: dns-preview [ZONE]' >&2
              ;;
            drift-check)
              printf '%s\n' 'usage: dns-drift-check [ZONE]' >&2
              ;;
            apply)
              printf '%s\n' 'usage: dns-apply --confirm [ZONE]' >&2
              ;;
          esac
          exit 64
        }

        if [ -z "''${CLOUDFLARE_DNS_TOKEN:-}" ]; then
          printf '%s\n' 'CLOUDFLARE_DNS_TOKEN must be set' >&2
          exit 2
        fi

        case "$mode" in
          apply)
            [ "''${1:-}" = '--confirm' ] || usage
            shift
            ;;
        esac

        [ "$#" -le 1 ] || usage
        domain_args=()
        if [ "$#" -eq 1 ]; then
          domain_args=(--domains "$1")
        fi

        umask 077
        creds="$(mktemp "''${TMPDIR:-/tmp}/dnscontrol-creds.XXXXXX")"
        cleanup() {
          rm -f "$creds"
        }
        trap cleanup EXIT HUP INT TERM

        printf '%s' '{"cloudflare":{"TYPE":"CLOUDFLAREAPI","apitoken":' > "$creds"
        printf '%s' "$CLOUDFLARE_DNS_TOKEN" | jq -Rs . >> "$creds"
        printf '%s\n' '}}' >> "$creds"
        chmod 600 "$creds"

        case "$mode" in
          preview)
            dnscontrol preview --no-colors --full --no-populate --ir ${ir} --creds "$creds" "''${domain_args[@]}"
            ;;
          drift-check)
            dnscontrol preview --no-colors --full --expect-no-changes --no-populate --ir ${ir} --creds "$creds" "''${domain_args[@]}"
            ;;
          apply)
            dnscontrol preview --no-colors --full --no-populate --ir ${ir} --creds "$creds" "''${domain_args[@]}"
            dnscontrol push --no-colors --full --no-populate --ir ${ir} --creds "$creds" "''${domain_args[@]}"
            ;;
        esac
      '';
    };
in
{
  preview = mkApp "dns-preview" "preview";
  driftCheck = mkApp "dns-drift-check" "drift-check";
  apply = mkApp "dns-apply" "apply";
}
```

- [ ] **Step 3: Wire the IR and apps into `flake.nix`**

Inside the main `let` in `flake.nix`, immediately after `nixpkgsFor`, add:

```nix
      dnsFor = system:
        let
          pkgs = nixpkgsFor.${system};
          dns = import ./dns { inherit pkgs; };
          apps = import ./dns/apps.nix {
            inherit pkgs;
            ir = dns.ir;
          };
        in
        {
          inherit apps dns;
        };
```

Extend the existing base attrset in the `packages` output, before its current `optionalAttrs` merge, to this exact shape:

```nix
        {
          bulwark-webmail = pkgs.bulwark-webmail;
          dnscontrol-ir = (dnsFor system).dns.ir;
          dns-preview = (dnsFor system).apps.preview;
          dns-drift-check = (dnsFor system).apps.driftCheck;
          dns-apply = (dnsFor system).apps.apply;
        }
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          do-image = self.nixosConfigurations."do-generic".config.system.build.digitalOceanImage;
        }
```

Add this top-level output beside `packages`, `checks`, and `devShells`:

```nix
      apps = forAllSystems (
        system:
        let
          dnsApps = (dnsFor system).apps;
        in
        {
          dns-preview = {
            type = "app";
            program = "${dnsApps.preview}/bin/dns-preview";
          };
          dns-drift-check = {
            type = "app";
            program = "${dnsApps.driftCheck}/bin/dns-drift-check";
          };
          dns-apply = {
            type = "app";
            program = "${dnsApps.apply}/bin/dns-apply";
          };
        }
      );
```

- [ ] **Step 4: Verify the public interface and the secret boundary**

Run:

```bash
make fmt
make setup-dummy-secrets
system="$(nix eval --impure --raw --expr builtins.currentSystem)"
nix build --print-build-logs .#dnscontrol-ir ".#checks.${system}.dns-render"
nix run .#dns-preview -- 2>&1 | grep -Fx 'CLOUDFLARE_DNS_TOKEN must be set'
nix run .#dns-drift-check -- 2>&1 | grep -Fx 'CLOUDFLARE_DNS_TOKEN must be set'
nix run .#dns-apply -- --confirm 2>&1 | grep -Fx 'CLOUDFLARE_DNS_TOKEN must be set'
make check
```

Expected: the IR and offline test build; all three apps fail before any network access with the exact missing-token message; `make check` evaluates the complete flake for its supported systems.

- [ ] **Step 5: Commit the flake interface**

```bash
git add dns/apps.nix flake.nix
git commit -m "feat: add DNSControl flake applications"
```

Expected: one commit containing only app construction and flake-output wiring.

### Task 3: Document and populate the authoritative DNS source

**Files:**
- Modify: `dns/zones.nix`
- Create: `docs/dns.md`
- Modify: `README.md:102-127`

**Interfaces:**
- Consumes: the four-type source schema and `nix run` interface from Tasks 1–2.
- Produces: reviewed authoritative zone declarations and an operator guide that makes the initial adoption non-destructive.

- [ ] **Step 1: Capture an offline inventory before declaring any production zone**

For each Cloudflare zone, record every manually managed A, CNAME, MX, and TXT record from the dashboard or Cloudflare API, including record name, value/target, MX priority, TTL, and proxy status. Keep the pre-adoption backup outside Git if its contents should not be committed.

Do not delete or edit records in the dashboard during this step. Cloudflare-managed SOA records, apex NS records, and Cloudflare Mail Routing MX/DKIM records are not to be declared because DNSControl's Cloudflare provider ignores them.

- [ ] **Step 2: Replace the empty `dns/zones.nix` attrset with the inventory using the exact source schema**

For every inventory record, add one attrset under its zone. Use `ttl = "auto"` only when Cloudflare currently reports Auto; use the current numeric TTL otherwise. Copy Cloudflare proxy state into `proxied` for every A or CNAME record. Preserve the trailing `.` on CNAME targets and MX exchanges.

A populated MX declaration must follow this exact shape:

```nix
{
  type = "MX";
  name = "@";
  priority = 10;
  exchange = "mail.example.com.";
  ttl = 3600;
}
```

A populated TXT declaration must follow this exact shape:

```nix
{
  type = "TXT";
  name = "@";
  text = "v=spf1 include:_spf.example.net -all";
  ttl = 3600;
}
```

- [ ] **Step 3: Write the operator guide**

Create `docs/dns.md` with these sections and commands:

````markdown
# Cloudflare DNS

## Source model

All managed records live in `dns/zones.nix`. Zones are authoritative: an ordinary Cloudflare DNS record missing from a declared zone is deleted by `dns-apply`. DNSControl ignores Cloudflare-maintained SOA, apex-NS, and Mail Routing MX/DKIM records.

## Cloudflare token

Create one token scoped only to the managed zones with `Zone / Zone / Read` and `Zone / DNS / Edit`. Make `CLOUDFLARE_DNS_TOKEN` available only through the operator's secret manager, then run:

```bash
# With CLOUDFLARE_DNS_TOKEN already exported without echoing it:
nix run .#dns-preview -- example.com
unset CLOUDFLARE_DNS_TOKEN
```

The wrapper creates a mode-`0600` temporary `creds.json` file and removes it on exit. Never place the token in Nix, Git, a `.env` file, or shell history.

## Commands

```bash
nix run .#dns-preview -- example.com
nix run .#dns-drift-check -- example.com
nix run .#dns-apply -- --confirm example.com
```

Omit the zone argument to operate on every declared zone. `dns-preview` is read-only. `dns-drift-check` returns non-zero when changes would be needed. `dns-apply` previews again before pushing and always uses `--no-populate`.

## Initial adoption and rollback

1. Take an offline inventory of current Cloudflare records.
2. Declare every intended A, CNAME, MX, and TXT record in `dns/zones.nix`.
3. Run `dns-preview` until every proposed change is intended; a pure adoption should show no correction.
4. Run `dns-apply -- --confirm` only after reviewing the output.
5. If a push fails partway through, rerun preview and apply after correcting the declaration. To roll back, revert `dns/zones.nix` to a known commit and apply that revision.

## GitHub Actions

The workflow uses the same `CLOUDFLARE_DNS_TOKEN` in the `cloudflare-dns-drift` and `cloudflare-dns-apply` environments. Restrict both environments to `main`; require reviewers only for `cloudflare-dns-apply`. Scheduled jobs fail on drift. Manual dispatch first publishes a live preview, then an `apply: true` run waits for Environment approval before applying the requested main-branch commit.
````

Append this documentation link to `README.md` after the Quick Start section:

```markdown
## Operations

- [Manage Cloudflare DNS declaratively](docs/dns.md)
```

- [ ] **Step 4: Validate the real declaration without changing Cloudflare**

Run:

```bash
make fmt
make setup-dummy-secrets
system="$(nix eval --impure --raw --expr builtins.currentSystem)"
nix build --print-build-logs ".#checks.${system}.dns-render"
# Export CLOUDFLARE_DNS_TOKEN from the operator's secret manager without echoing it.
nix run .#dns-preview --
unset CLOUDFLARE_DNS_TOKEN
```

Expected: the renderer check succeeds. The preview output contains no unintended deletion; for a pure adoption it reports no changes. If it proposes an unexpected change, correct `dns/zones.nix` and repeat this step; do not apply.

- [ ] **Step 5: Commit the reviewed declarations and guide**

```bash
git add dns/zones.nix docs/dns.md README.md
git commit -m "docs: add Cloudflare DNS operations guide"
```

Expected: the committed Nix source contains all intended records and no token or local backup.

### Task 4: Extend existing validation and add scheduled drift plus reviewer-gated apply

**Files:**
- Modify: `.github/workflows/check.yml`
- Create: `.github/workflows/dns.yml`

**Interfaces:**
- Consumes: flake apps from Task 2 and `CLOUDFLARE_DNS_TOKEN` as an Environment secret.
- Produces: existing PR/main validation extended with the offline renderer check, plus scheduled live drift failure, manual preview, and manual `apply: true` gated after preview by `cloudflare-dns-apply` reviewers.

- [ ] **Step 1: Extend the existing secret-free flake-check workflow**

In `.github/workflows/check.yml`, add this step after **Check Nix flake** and before **Check formatting**:

```yaml
      - name: Run offline DNS renderer check
        run: nix build --print-build-logs .#checks.x86_64-linux.dns-render
```

This job already runs on pull requests and pushes to `main`, installs Nix, and invokes `make setup-dummy-secrets`; it must not receive the Cloudflare token.

- [ ] **Step 2: Create the privileged DNS workflow before configuring any GitHub secret**

Create `.github/workflows/dns.yml`:

```yaml
name: Manage Cloudflare DNS

on:
  schedule:
    - cron: "17 3 * * *"
  workflow_dispatch:
    inputs:
      commit:
        description: "Full 40-character commit SHA reachable from main"
        required: true
        type: string
      apply:
        description: "Apply after the preview job completes and Environment approval is granted"
        required: true
        default: false
        type: boolean

permissions:
  contents: read

jobs:
  scheduled-drift:
    if: github.event_name == 'schedule'
    runs-on: ubuntu-latest
    environment: cloudflare-dns-drift
    steps:
      - uses: actions/checkout@v4

      - uses: cachix/install-nix-action@v25
        with:
          nix_path: nixpkgs=channel:nixos-unstable

      - name: Set up dummy secrets
        run: make setup-dummy-secrets

      - name: Detect Cloudflare DNS drift
        env:
          CLOUDFLARE_DNS_TOKEN: ${{ secrets.CLOUDFLARE_DNS_TOKEN }}
        run: nix run .#dns-drift-check --

  manual-preview:
    if: github.event_name == 'workflow_dispatch'
    runs-on: ubuntu-latest
    environment: cloudflare-dns-drift
    steps:
      - name: Check out default branch
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Verify requested commit and check it out
        env:
          REQUESTED_COMMIT: ${{ inputs.commit }}
        run: |
          set -euo pipefail
          test "$GITHUB_REF" = "refs/heads/main"
          [[ "$REQUESTED_COMMIT" =~ ^[0-9a-f]{40}$ ]]
          git fetch --no-tags origin main
          git rev-parse --verify "${REQUESTED_COMMIT}^{commit}"
          git merge-base --is-ancestor "$REQUESTED_COMMIT" origin/main
          git checkout --detach "$REQUESTED_COMMIT"

      - uses: cachix/install-nix-action@v25
        with:
          nix_path: nixpkgs=channel:nixos-unstable

      - name: Set up dummy secrets
        run: make setup-dummy-secrets

      - name: Preview Cloudflare DNS changes
        env:
          CLOUDFLARE_DNS_TOKEN: ${{ secrets.CLOUDFLARE_DNS_TOKEN }}
        run: nix run .#dns-preview --

  apply:
    if: github.event_name == 'workflow_dispatch' && inputs.apply
    needs: manual-preview
    runs-on: ubuntu-latest
    environment: cloudflare-dns-apply
    concurrency:
      group: cloudflare-dns-apply
      cancel-in-progress: false
    steps:
      - name: Check out default branch
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Verify requested commit and check it out
        env:
          REQUESTED_COMMIT: ${{ inputs.commit }}
        run: |
          set -euo pipefail
          test "$GITHUB_REF" = "refs/heads/main"
          [[ "$REQUESTED_COMMIT" =~ ^[0-9a-f]{40}$ ]]
          git fetch --no-tags origin main
          git rev-parse --verify "${REQUESTED_COMMIT}^{commit}"
          git merge-base --is-ancestor "$REQUESTED_COMMIT" origin/main
          git checkout --detach "$REQUESTED_COMMIT"

      - uses: cachix/install-nix-action@v25
        with:
          nix_path: nixpkgs=channel:nixos-unstable

      - name: Set up dummy secrets
        run: make setup-dummy-secrets

      - name: Apply Cloudflare DNS changes
        env:
          CLOUDFLARE_DNS_TOKEN: ${{ secrets.CLOUDFLARE_DNS_TOKEN }}
        run: nix run .#dns-apply -- --confirm
```

- [ ] **Step 3: Run static workflow validation and repository checks**

Run:

```bash
make fmt
ruby -e 'require "yaml"; YAML.load_file(".github/workflows/check.yml"); YAML.load_file(".github/workflows/dns.yml"); puts "valid YAML"'
git diff --check -- .github/workflows/check.yml .github/workflows/dns.yml flake.nix dns README.md docs/dns.md
make setup-dummy-secrets
make check
system="$(nix eval --impure --raw --expr builtins.currentSystem)"
nix build --print-build-logs ".#checks.${system}.dns-render"
```

Expected: Ruby prints `valid YAML`; whitespace validation produces no output; `make check` and the offline renderer test succeed. This validation intentionally does not receive a Cloudflare token.

- [ ] **Step 4: Commit the CI workflows**

```bash
git add .github/workflows/check.yml .github/workflows/dns.yml
git commit -m "ci: manage Cloudflare DNS safely"
```

Expected: one commit containing only the DNS CI changes.

### Task 5: Configure external controls and perform the first controlled reconciliation

**Files:**
- Verify: `dns/zones.nix`
- Verify: `docs/dns.md`
- Verify: `.github/workflows/dns.yml`

**Interfaces:**
- Consumes: the committed source and workflow from Tasks 1–4.
- Produces: a Cloudflare/CI configuration that can reconcile live zones only after a human reviews preview output.

- [ ] **Step 1: Create and scope the Cloudflare token**

In Cloudflare, create one API token restricted to the managed zone resources with exactly these permissions:

```text
Zone / Zone / Read
Zone / DNS / Edit
```

Do not grant SSL, Page Rules, Workers, Account, or global API-key permissions. Store the token in the operator's local secret manager; do not save it in the repository or Nix configuration.

- [ ] **Step 2: Configure the two GitHub Environments with the same token value**

Create `cloudflare-dns-drift` and `cloudflare-dns-apply` in the repository's GitHub Environments settings. Restrict both to the `main` branch. Add `CLOUDFLARE_DNS_TOKEN` with the same Cloudflare token value to each Environment. Require one or more reviewers only on `cloudflare-dns-apply`.

Expected: scheduled drift jobs can run only from trusted `main`; the `apply` job pauses after manual-preview output until a reviewer approves it.

- [ ] **Step 3: Prove zero-surprise adoption locally**

Run:

```bash
# Export CLOUDFLARE_DNS_TOKEN from the operator's secret manager without echoing it.
nix run .#dns-preview --
unset CLOUDFLARE_DNS_TOKEN
```

Expected: no record is proposed for deletion unless it is intentionally absent from `dns/zones.nix`. For a pure dashboard-to-Nix adoption, the preview reports no changes. If that condition is not met, update and recommit the declaration before proceeding.

- [ ] **Step 4: Exercise manual preview and approval-gated apply**

1. Push the committed configuration to `main`.
2. Dispatch **Manage Cloudflare DNS** from `main` with the full SHA of that commit and `apply: false`; inspect the `manual-preview` output.
3. Dispatch it again with the same full SHA and `apply: true`.
4. Inspect the completed `manual-preview` job, then approve the waiting `cloudflare-dns-apply` Environment deployment only if every correction is intended.
5. After the apply succeeds, run a local drift check:

```bash
# Export CLOUDFLARE_DNS_TOKEN from the operator's secret manager without echoing it.
nix run .#dns-drift-check --
unset CLOUDFLARE_DNS_TOKEN
```

Expected: the final drift check exits zero. If an apply fails partway through, do not retry blindly: run preview, correct the committed Nix source if necessary, and use a newly reviewed manual dispatch.

- [ ] **Step 5: Verify the final diff and commit history**

Run:

```bash
make setup-dummy-secrets
make check
git diff --check origin/main...HEAD -- dns flake.nix README.md docs/dns.md .github/workflows/check.yml .github/workflows/dns.yml
git log --oneline origin/main..HEAD
git status --short --branch
```

Expected: `make check` succeeds, whitespace validation produces no output, commits are focused on renderer/apps, declarations/docs, and CI, and Git status contains no token, `creds.json`, backup, or generated result file.

## Plan Self-Review

- **Spec coverage:** Task 1 supplies the direct Nix source, pure IR renderer, record validation, deterministic fixture, and pinned DNSControl decoding. Task 2 supplies the three secret-safe apps and `--no-populate` enforcement. Task 3 covers manual-record adoption, documentation, live zero-surprise preview, partial-failure recovery, and Git rollback. Task 4 covers PR static validation, scheduled drift, immutable main-commit manual preview, post-preview Environment approval, single-token dual-environment storage, and apply serialization. Task 5 covers Cloudflare/GitHub configuration and the first controlled reconciliation.
- **Type consistency:** Tasks use one record schema (`address`, `target`, `priority`/`exchange`, `text`), one renderer interface (`render`), one IR attribute (`ir`), and the three exported app names consistently.
- **Scope:** The initial implementation deliberately rejects unsupported record types and all non-DNS Cloudflare resources. Extending the model begins with a renderer fixture and a new source-schema branch, not unchecked raw JSON.
