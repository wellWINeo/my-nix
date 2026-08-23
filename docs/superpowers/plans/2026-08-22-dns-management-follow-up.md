# DNS Management Follow-up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Adopt the two reviewed Cloudflare zones, close DNS review gaps, and deploy a reusable `managing-dns` operator skill.

**Architecture:** `dns/zones.nix` remains the authoritative non-secret source and is populated from the reviewed exports. Renderer assertions and a new generated-app safety derivation protect the IR and wrapper boundary offline. The DNS skill is repository-local under `.agents/skills`; Claude consumes the same directory through a relative symlink.

**Tech Stack:** Nix flakes, dnscontrol, Bash, jq, GitHub Actions, Markdown skills.

## Global Constraints

- Declare only A, ALIAS, CNAME, MX, and TXT records from the reviewed exports; omit Cloudflare SOA and apex NS records. Use ALIAS for the proxied `uspenskiy.tech` apex target because DNSControl rejects apex CNAME source records and its Cloudflare provider rewrites ALIAS to the Cloudflare CNAME representation; do not enable per-record CNAME flattening.
- Map exported TTL `1` to `ttl = "auto"`; preserve numeric TTLs, proxy state, and trailing dots on ALIAS/CNAME/MX targets.
- `CLOUDFLARE_DNS_TOKEN` must not be committed, passed as a command argument, emitted in logs, or written to a derivation.
- Every live DNSControl invocation retains `--no-populate`; no live push is part of this change.
- Keep the flake evaluation set unchanged: `x86_64-linux`, `aarch64-linux`, and `aarch64-darwin`.
- New skill path is exactly `.agents/skills/managing-dns/SKILL.md`; `.claude/skills` is the symlink `../.agents/skills`.

---

## File structure

- `dns/zones.nix` — reviewed authoritative declarations for both zones.
- `dns/apps.nix` — runtime-only credentials and fixed DNSControl invocation arguments.
- `dns/tests/default.nix` — renderer fixture semantic assertions.
- `dns/tests/apps.nix` — offline app-wrapper safety derivation.
- `dns/flake-outputs.nix` — exports the new app-safety check.
- `.github/workflows/check.yml` — builds the app-safety check in secret-free CI.
- `docs/dns.md` — warns about local/CI apply coordination.
- `.agents/skills/managing-dns/SKILL.md` — reusable edit/check/preview/apply workflow.
- `.claude/skills` — relative symlink to the shared skill directory.
- `AGENTS.md` — directs agents to the DNS skill.

### Task 1: Add regression coverage for renderer and application safety

**Files:**
- Modify: `dns/tests/default.nix`
- Create: `dns/tests/apps.nix`
- Modify: `dns/flake-outputs.nix`
- Modify: `.github/workflows/check.yml`

**Interfaces:**
- Consumes: `apps.preview`, `apps.driftCheck`, and `apps.apply` from `dns/apps.nix`.
- Produces: `checks.<system>.dns-app-safety`, a derivation that validates the generated executable wrappers without credentials or network access.

- [ ] **Step 1: Extend the fixture assertion before changing production code**

In `dns/tests/default.nix`, extend the existing `jq -e` expression after the proxy assertions:

```jq
and .domains[0].records[0].target == "192.0.2.10"
and .domains[0].records[0].ttl == 1
and .domains[0].records[1].target == "origin.example.net."
and .domains[0].records[1].ttl == 300
and .domains[0].records[2].target == "mail.example.test."
and .domains[0].records[2].ttl == 3600
and .domains[0].records[3].ttl == 3600
```

- [ ] **Step 2: Run the renderer check to establish the semantic assertion result**

Run:

```bash
make setup-dummy-secrets
system="$(nix eval --impure --raw --expr builtins.currentSystem)"
nix build --print-build-logs ".#checks.${system}.dns-render"
```

Expected: `dnscontrol check` prints `No errors.` and the strengthened assertions pass, documenting the already-correct renderer behavior.

- [ ] **Step 3: Write the failing app-safety check interface**

Create `dns/tests/apps.nix` with a deliberate reference to the not-yet-exported app check input:

```nix
{ pkgs, apps }:
pkgs.runCommand "dns-app-safety-test"
  {
    nativeBuildInputs = [
      pkgs.coreutils
      pkgs.gnugrep
    ];
  }
  ''
    set -euo pipefail

    checkMissingToken() {
      local executable="$1"
      local output
      if output="$(env -u CLOUDFLARE_DNS_TOKEN "$executable" 2>&1)"; then
        printf '%s\n' "expected $executable to reject a missing token" >&2
        exit 1
      fi
      test "$output" = 'CLOUDFLARE_DNS_TOKEN must be set'
    }

    checkMissingToken ${apps.preview}/bin/dns-preview
    checkMissingToken ${apps.driftCheck}/bin/dns-drift-check
    checkMissingToken ${apps.apply}/bin/dns-apply

    for executable in \
      ${apps.preview}/bin/dns-preview \
      ${apps.driftCheck}/bin/dns-drift-check \
      ${apps.apply}/bin/dns-apply; do
      grep -F -- '--no-populate --ir ' "$executable"
      grep -F -- '--creds "$creds"' "$executable"
    done

    touch "$out"
  ''
```

In `dns/flake-outputs.nix`, temporarily add this incorrect check to the `checks` attrset to prove the missing wiring:

```nix
dns-app-safety = import ./tests/apps.nix { inherit pkgs; };
```

- [ ] **Step 4: Run the new check and verify it fails for the missing `apps` argument**

Run:

```bash
system="$(nix eval --impure --raw --expr builtins.currentSystem)"
nix build ".#checks.${system}.dns-app-safety"
```

Expected: evaluation fails because `dns/tests/apps.nix` requires `apps`.

- [ ] **Step 5: Wire the generated apps into the safety check**

In the `checks` function of `dns/flake-outputs.nix`, bind both values:

```nix
apps = (dnsFor system).apps;
dns = (dnsFor system).dns;
```

Then replace the temporary check with:

```nix
dns-app-safety = import ./tests/apps.nix { inherit pkgs apps; };
```

In `.github/workflows/check.yml`, add the new output to the existing DNS build command:

```yaml
            .#checks.x86_64-linux.dns-render \
            .#checks.x86_64-linux.dns-config \
            .#checks.x86_64-linux.dns-app-safety
```

- [ ] **Step 6: Run regression checks and format**

Run:

```bash
make fmt
make setup-dummy-secrets
system="$(nix eval --impure --raw --expr builtins.currentSystem)"
nix build --print-build-logs \
  ".#checks.${system}.dns-render" \
  ".#checks.${system}.dns-config" \
  ".#checks.${system}.dns-app-safety"
ruby -e 'require "yaml"; YAML.load_file(".github/workflows/check.yml"); puts "valid YAML"'
```

Expected: all derivations build, each app prints the exact missing-token message inside the safety derivation, and Ruby prints `valid YAML`.

- [ ] **Step 7: Commit the regression coverage**

```bash
git add dns/tests/default.nix dns/tests/apps.nix dns/flake-outputs.nix .github/workflows/check.yml
git commit -m "test: cover DNS renderer and app safety"
```

### Task 2: Simplify the credentials wrapper and document apply coordination

**Files:**
- Modify: `dns/apps.nix`
- Modify: `docs/dns.md`

**Interfaces:**
- Preserves the public app names and command forms: `dns-preview [ZONE]`, `dns-drift-check [ZONE]`, and `dns-apply --confirm [ZONE]`.
- Preserves the temporary credential schema `{"cloudflare":{"TYPE":"CLOUDFLAREAPI","apitoken":"…"}}`.

- [ ] **Step 1: Confirm the existing app-safety check catches wrapper regressions**

Temporarily remove `--no-populate` from one DNSControl invocation in `dns/apps.nix` without saving it to a commit, then run:

```bash
system="$(nix eval --impure --raw --expr builtins.currentSystem)"
nix build ".#checks.${system}.dns-app-safety"
```

Expected: failure from the `grep -F -- '--no-populate --ir '` assertion. Restore the unchanged invocation before proceeding.

- [ ] **Step 2: Replace manual JSON construction and rename the shell array**

In `dns/apps.nix`, replace the credential-file writes:

```bash
printf '%s' '{"cloudflare":{"TYPE":"CLOUDFLAREAPI","apitoken":' > "$creds"
printf '%s' "$CLOUDFLARE_DNS_TOKEN" | jq -Rs . >> "$creds"
printf '%s\n' '}}' >> "$creds"
```

with:

```bash
jq -n --arg apitoken "$CLOUDFLARE_DNS_TOKEN" \
  '{ cloudflare: { TYPE: "CLOUDFLAREAPI", apitoken: $apitoken } }' > "$creds"
```

Rename every `domain_args` occurrence to `domainArgs`, including the `dnscontrol` argument expansions:

```bash
domainArgs=()
# …
domainArgs=(--domains "$1")
# …
"''${domainArgs[@]}"
```

- [ ] **Step 3: Add the operator coordination warning**

Append this sentence to the `## GitHub Actions` paragraph in `docs/dns.md`:

```markdown
Do not run a local `dns-apply` while a CI apply may be pending or running; use the CI workflow for normal production reconciliation.
```

- [ ] **Step 4: Run the safety test and public missing-token smoke tests**

Run:

```bash
make fmt
make setup-dummy-secrets
system="$(nix eval --impure --raw --expr builtins.currentSystem)"
nix build --print-build-logs ".#checks.${system}.dns-app-safety"
for app in dns-preview dns-drift-check; do
  nix run ".#$app" -- 2>&1 | grep -Fx 'CLOUDFLARE_DNS_TOKEN must be set'
done
nix run .#dns-apply -- --confirm 2>&1 | grep -Fx 'CLOUDFLARE_DNS_TOKEN must be set'
```

Expected: the safety derivation builds and all three public commands emit only the exact missing-token message before any network call.

- [ ] **Step 5: Commit the wrapper and documentation fixes**

```bash
git add dns/apps.nix docs/dns.md
git commit -m "fix: harden DNS application checks"
```

### Task 3: Populate the reviewed authoritative zones

**Files:**
- Modify: `dns/zones.nix`

**Interfaces:**
- Produces the authoritative `zones` attrset consumed by `dns/default.nix`.
- Declares both `uspenskiy.tech` and `uspenskiy.su` with only reviewed A, ALIAS, CNAME, MX, and TXT records.

- [ ] **Step 1: Replace the empty zone source with the reviewed inventory**

Replace `dns/zones.nix` with:

```nix
{
  "uspenskiy.tech" = {
    records = [
      {
        type = "A";
        name = "mokosh";
        address = "104.248.201.56";
        proxied = false;
        ttl = "auto";
      }
      {
        type = "CNAME";
        name = "ebooks";
        target = "mokosh.uspenskiy.tech.";
        proxied = true;
        ttl = "auto";
      }
      {
        type = "CNAME";
        name = "gw";
        target = "mokosh.uspenskiy.tech.";
        proxied = true;
        ttl = "auto";
      }
      {
        type = "CNAME";
        name = "readlater";
        target = "mokosh.uspenskiy.tech.";
        proxied = true;
        ttl = "auto";
      }
      {
        type = "CNAME";
        name = "rss";
        target = "mokosh.uspenskiy.tech.";
        proxied = true;
        ttl = "auto";
      }
      {
        type = "ALIAS";
        name = "@";
        target = "website-63n.pages.dev.";
        proxied = true;
        ttl = "auto";
      }
      {
        type = "CNAME";
        name = "vault";
        target = "mokosh.uspenskiy.su.";
        proxied = true;
        ttl = "auto";
      }
      {
        type = "TXT";
        name = "@";
        text = "google-site-verification=lsPPY-JWZW7_BDMm_n2rMRNpXGC1-W9vNOoI7qJJIi8";
        ttl = 3600;
      }
    ];
  };

  "uspenskiy.su" = {
    records = [
      {
        type = "A";
        name = "mokosh";
        address = "104.248.201.56";
        proxied = false;
        ttl = "auto";
      }
      {
        type = "A";
        name = "@";
        address = "104.248.201.56";
        proxied = true;
        ttl = "auto";
      }
      {
        type = "A";
        name = "veles";
        address = "85.239.58.14";
        proxied = false;
        ttl = "auto";
      }
      {
        type = "CNAME";
        name = "blog";
        target = "uspenskiy.tech.";
        proxied = true;
        ttl = "auto";
      }
      {
        type = "CNAME";
        name = "ebooks";
        target = "uspenskiy.su.";
        proxied = true;
        ttl = "auto";
      }
      {
        type = "CNAME";
        name = "gw";
        target = "mokosh.uspenskiy.su.";
        proxied = false;
        ttl = "auto";
      }
      {
        type = "CNAME";
        name = "mail";
        target = "mokosh.uspenskiy.su.";
        proxied = false;
        ttl = "auto";
      }
      {
        type = "CNAME";
        name = "vault";
        target = "mokosh.uspenskiy.su.";
        proxied = true;
        ttl = "auto";
      }
      {
        type = "MX";
        name = "@";
        priority = 0;
        exchange = "mokosh.uspenskiy.su.";
        ttl = "auto";
      }
      {
        type = "TXT";
        name = "default._domainkey";
        text = "v=DKIM1; k=ed25519; p=dxYWpcOjJWVR7BHdEpIIq2pfua4mgLVI+LoBbixRxqE=";
        ttl = "auto";
      }
      {
        type = "TXT";
        name = "_dmarc";
        text = "v=DMARC1;  p=quarantine; rua=mailto:048649a56a38489db9976224f65ef9a1@dmarc-reports.cloudflare.net";
        ttl = "auto";
      }
      {
        type = "TXT";
        name = "rsa._domainkey";
        text = "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAkJF0Phngwj2pFOkSi20Et2QY+ZYYhrYh2GvtPFE8dWVPF6U15tvY+VCnPcEMJKew5x1x6sX8xWjKcdcLhiXvlfHic9grfFp2rhwJAWK3c3RTNXmdQG9dka7d8lwm/0WO9wWat3+p5QZuXDHfgu5B5Vg7YONadoUvmX9iO26szPMB+1QrmJF/RXZtJ+KpK95V0eCOWw8kTF4IDcZ1AxWKfjJnESxg34bLQ8kLkpEOsLmTkbW6xUlFuY+aj6rhW1ggyB8JIfxo6dQ+MCAWlfLhaCgX1VFA01C38g11r+mg+i49K0gkReofHEDwp+boc4ytewtob09sqhPFgqEnl9pxHwIDAQAB";
        ttl = "auto";
      }
      {
        type = "TXT";
        name = "@";
        text = "v=spf1 mx -all";
        ttl = "auto";
      }
    ];
  };
}
```

- [ ] **Step 2: Build the production IR offline**

Run:

```bash
make fmt
make setup-dummy-secrets
system="$(nix eval --impure --raw --expr builtins.currentSystem)"
nix build --print-build-logs ".#checks.${system}.dns-config"
```

Expected: `dnscontrol check --ir` prints `No errors.` for the populated source.

- [ ] **Step 3: Inspect the rendered zones before a live request**

Run:

```bash
nix build .#dnscontrol-ir
jq '.domains[] | { name, records: (.records | length) }' result
rm result
```

Expected: two domains named `uspenskiy.su` and `uspenskiy.tech`; no token, credential file, or generated result symlink remains afterwards.

- [ ] **Step 4: Run a live zero-surprise preview only with an operator-provided token**

Run only after exporting the token from the operator's secret manager without echoing it:

```bash
nix run .#dns-preview --
unset CLOUDFLARE_DNS_TOKEN
```

Expected: the preview has no unintended creates, deletes, or modifications. Stop and correct `dns/zones.nix` if it does; do not run `dns-apply` in this task.

- [ ] **Step 5: Commit the reviewed declarations**

```bash
git add dns/zones.nix
git commit -m "feat: manage Cloudflare DNS zones"
```

### Task 4: Create and deploy the shared DNS-management skill

**Files:**
- Create: `.agents/skills/managing-dns/SKILL.md`
- Create: `.claude/skills` (symlink to `../.agents/skills`)
- Modify: `AGENTS.md`

**Interfaces:**
- The skill is discovered at `.agents/skills/managing-dns/SKILL.md` by shared agents and via `.claude/skills` by Claude.
- The skill never stores or echoes `CLOUDFLARE_DNS_TOKEN` and never directs an agent to apply without a reviewed preview.

- [ ] **Step 1: Run a baseline retrieval scenario without the new skill**

Dispatch a read-only subagent without loading the new skill with this prompt:

```text
An operator wants to change a Cloudflare CNAME in this repository and apply it quickly. State the exact safe edit, validation, preview, drift, and apply sequence. Include where the token may be stored and the condition that must be met before applying.
```

Record omissions from its response in the implementation notes. Expected baseline failure: it may omit the authoritative-deletion warning, offline flake checks, `--confirm`, or the review-before-apply gate.

- [ ] **Step 2: Create the skill with the required operator workflow**

Create `.agents/skills/managing-dns/SKILL.md` with this content:

```markdown
---
name: managing-dns
description: Use when editing, validating, previewing, checking drift, or applying declarative Cloudflare DNS records in this Nix configuration repository.
---

# Managing DNS

## Scope

The authoritative non-secret source is `dns/zones.nix`. Use this skill before changing a managed DNS record or invoking a DNSControl app.

## Safety rules

- A declared zone is authoritative: an ordinary A, ALIAS, CNAME, MX, or TXT record omitted from it is deleted by `dns-apply`.
- Before adding a record type other than A, ALIAS, CNAME, MX, or TXT, extend `dns/lib.nix`, `dns/tests/zones.nix`, and `dns/tests/default.nix` first.
- Keep `CLOUDFLARE_DNS_TOKEN` in an operator secret manager or GitHub Environment only. Never add it to Nix, Git, `.env`, arguments, logs, or artifacts.
- Never apply from an unreviewed preview. Do not run a local apply while a CI apply is pending or running.

## Edit records

1. Edit `dns/zones.nix` using relative names (`@` for the apex).
2. Use `address` for A; absolute `target` for ALIAS and CNAME; `priority` and absolute `exchange` for MX; and `text` for TXT.
3. Use ALIAS for a proxied apex target: DNSControl rejects apex CNAME source records, while its Cloudflare provider rewrites ALIAS to Cloudflare's CNAME representation. Do not enable per-record CNAME flattening.
4. Preserve ALIAS/CNAME/MX trailing dots, A/ALIAS/CNAME `proxied` state, and `ttl = "auto"` when Cloudflare reports Auto.
5. For first adoption, inventory every existing ordinary record. Do not declare Cloudflare SOA or apex NS records.

## Validate offline

```bash
make fmt
make setup-dummy-secrets
system="$(nix eval --impure --raw --expr builtins.currentSystem)"
nix build --print-build-logs \
  ".#checks.${system}.dns-render" \
  ".#checks.${system}.dns-config" \
  ".#checks.${system}.dns-app-safety"
make check
```

## Preview, drift, and apply

Export the token without printing it, then use exactly one of:

```bash
nix run .#dns-preview -- [ZONE]
nix run .#dns-drift-check -- [ZONE]
nix run .#dns-apply -- --confirm [ZONE]
```

Omit `[ZONE]` for all declared zones. Preview must contain only intended changes. Drift check returns non-zero when reconciliation is needed. Apply previews again before push; run it only after a human has reviewed that preview. Unset the token immediately afterwards:

```bash
unset CLOUDFLARE_DNS_TOKEN
```

## CI

Pull-request checks are secret-free. Scheduled drift and manual preview use `cloudflare-dns-drift`; approved apply uses `cloudflare-dns-apply`. Dispatch manual CI from `main` with a full reachable commit SHA, inspect preview output, and approve the Environment deployment only when every change is intended.
```

- [ ] **Step 3: Install the shared Claude skill symlink and AGENTS reference**

Run:

```bash
mkdir -p .agents/skills
ln -s ../.agents/skills .claude/skills
readlink .claude/skills | grep -Fx '../.agents/skills'
```

Add this section before `## Common Tasks` in `AGENTS.md`:

```markdown
## Declarative DNS

Before editing, validating, previewing, checking drift, or applying Cloudflare DNS declarations, read `.agents/skills/managing-dns/SKILL.md`.
```

- [ ] **Step 4: Repeat the retrieval scenario with the skill available**

Dispatch a fresh read-only subagent with the same scenario from Step 1, but explicitly provide `.agents/skills/managing-dns/SKILL.md`. Expected: it names `dns/zones.nix`, warns that omission deletes records, runs offline checks, keeps the token out of files/logs, requires reviewed preview before `dns-apply -- --confirm`, and unsets the token afterwards.

- [ ] **Step 5: Validate skill deployment and commit**

Run:

```bash
wc -w .agents/skills/managing-dns/SKILL.md
test -L .claude/skills
readlink .claude/skills | grep -Fx '../.agents/skills'
git diff --check -- .agents/skills/managing-dns/SKILL.md .claude/skills AGENTS.md
```

Expected: the skill is concise, the symlink target is exact, and whitespace validation produces no output.

```bash
git add .agents/skills/managing-dns/SKILL.md .claude/skills AGENTS.md
git commit -m "docs: add DNS management skill"
```

### Task 5: Run complete repository validation

**Files:**
- Verify: `dns/`, `.github/workflows/check.yml`, `docs/dns.md`, `.agents/skills/managing-dns/SKILL.md`, `.claude/skills`, `AGENTS.md`

- [ ] **Step 1: Run all offline validation**

Run:

```bash
make fmt
make setup-dummy-secrets
ruby -e 'require "yaml"; YAML.load_file(".github/workflows/check.yml"); YAML.load_file(".github/workflows/dns.yml"); puts "valid YAML"'
system="$(nix eval --impure --raw --expr builtins.currentSystem)"
nix build --print-build-logs \
  ".#checks.${system}.dns-render" \
  ".#checks.${system}.dns-config" \
  ".#checks.${system}.dns-app-safety"
make check
git diff --check origin/main...HEAD -- dns .github/workflows/check.yml docs/dns.md .agents/skills/managing-dns AGENTS.md
```

Expected: Ruby prints `valid YAML`; all three DNS checks build; `make check` succeeds; whitespace validation produces no output.

- [ ] **Step 2: Verify the final working tree**

Run:

```bash
git status --short --branch
git log --oneline origin/main..HEAD
```

Expected: no token, credentials JSON, exports, `result` symlink, or untracked generated output is present. The history contains focused coverage, wrapper/docs, zone adoption, and skill commits.
