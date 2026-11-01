---
name: triaging-vulnerabilities
description: Use when triaging, categorizing, labeling, or closing security issues created by the buildtime SBOM vulnerability scan in this repository.
---

# Triaging vulnerability issues

## Scope

The vulnerability workflow (`scripts/vulnerability/`, `.github/workflows/vulnerability-scan.yml`) creates one marker-keyed issue per advisory under the title `Security: <advisory> in <package>`. Triage assigns each issue exactly one category label. Use this skill before categorizing scan issues, applying triage labels, or closing issues as not affected.

## Categories and labels

| Label | Meaning | Reconciliation effect |
|---|---|---|
| `vuln:not_affected` | Advisory does not apply: affected range excludes installed versions, wrong package identity, or vulnerable path provably unreachable | Suppressed: closed once, never recreated while labeled |
| `vuln:easyfix` | Fixed version exists and is routine to adopt (nixpkgs stable bump / flake-lock update, no breaking changes) | None (advisory) |
| `vuln:fix_available` | Fix exists upstream but adoption is non-trivial (unstable-only, overlay/backport, breaking major, config migration) | None (advisory) |
| `vuln:fix_not_available` | No fixed release exists upstream (or upstream wontfix) | None (advisory) |
| `vuln:wontfix` | Operator explicitly declines action despite applicability | Suppressed: closed once, never recreated while labeled |

Only `vuln:not_affected` and `vuln:wontfix` suppress. Removing a suppression label resumes normal enforcement (including reopening).

## Decision rules

1. **Buildtime closure is not runtime presence.** The whole scan inventories the recursive derivation closure; every issue body says so. That fact alone never justifies `not_affected` — but it is required context for reachability arguments.
2. **`not_affected` requires positive proof**: version-range exclusion verified against OSV/NVD records, a package-identity mismatch (e.g. `google/wire` the Go tool vs Wire the messenger), or a provably unreachable path (feature not compiled in — check nixpkgs build flags; Windows-only code; absent hardware). Prefer fixing over assuming away.
3. **easyfix vs fix_available** divides on nixpkgs adoption cost, not on upstream existence: fixed in the tracked `nixos-25.11` channel (or a trivially bumped lock) = easyfix; anything needing unstable pinning, overlays, backports, or breaking migrations = fix_available.
4. **Never invent fixed versions.** Unverifiable claims keep the first-pass category with low confidence and a note.
5. Host context matters: mokosh (web/mail/VPN/vault/blog/RSS/calibre/backup), veles (xray relay), buyan (xray entry), nixpi (media/NAS/DNS/DHCP/photos/torrent). A server-side vuln in a client-only build may be not_affected; the same vuln on the host actually running the service is not.

## Agent triage procedure

1. **Collect**: `gh issue list --state open --limit 1000 --json number,title,body` — parse each body's `<!-- evidence-json-base64:... -->` block for `{advisory, aliases, package, versions, hosts, store_paths, references}`.
2. **Batch by component** (`pname`): components with ≥8 advisories get one batch each; smaller ones are grouped alphabetically into mixed batches of ~10 components. Write one `<batch>-input.json` per batch (compact: number, advisory, aliases≤4, versions≤3, hosts, one derivation path, references≤3).
3. **First pass (cheap model, e.g. `glm-5.3-flash`)**: one worker subagent per batch reads the input file and writes `<batch>-flash.json` verdicts `{number, category, confidence, rationale≤200, misdetection}` using the decision rules above. Knowledge-based; no fabricated data.
4. **Verification (stronger model, e.g. `gpt-6-luna`)**: one worker per batch verifies flash verdicts against live OSV (`https://api.osv.dev/v1/vulns/{id}`) / NVD (`https://services.nvd.nist.gov/rest/json/cves/2.0?cveId={id}`) records — every `not_affected`/`misdetection` claim individually, every low-confidence verdict, easyfix/fix_available boundary spot-checks. Writes `<batch>-verify.json` `{number, verdict: confirmed|disagree, category, reason, checked}`.
5. **Adjudicate**: the parent session merges confirmed verdicts, applies disagreements, and sanity-checks per-component category distributions for pattern errors.
6. **Rate exploitability** (see below) for everything not suppressed: `vuln:critical` / `vuln:high` / `vuln:medium` / `vuln:low`.
7. **Concurrency cap**: at most 5 subagents in parallel (provider rate limits); dispatch batches in sequential chunks of ≤4–5 via a scripted workflow (`runs.all` per chunk).
8. **Apply**: label every issue with its final category **and** rating; close `not_affected` issues with a one-line rationale comment (see below). For `fix_available` / `fix_not_available`, post a triage comment answering: why it is not an easy update, whether it is exploitable in this config, whether it is exploitable without authentication, and the rating. Label application is idempotent — safe to re-run for missed issues.

## Applying results

```bash
gh issue edit <number> --repo wellWINeo/my-nix --add-label "vuln:<category>"
gh issue close <number> --repo wellWINeo/my-nix --comment "Triaged **not affected**: <rationale>. Suppressed via \`vuln:not_affected\`; the scanner keeps this closed while the label stays. See .agents/skills/triaging-vulnerabilities."
```

Close only `not_affected` (and explicit `wontfix`) issues. The reconcile step in the workflow treats those labels as suppression; all other categories stay open.

## Scanner feedback (misdetections)

If triage finds scanner false positives — version-range exclusions (fix already in the installed version, common for kernel/CPython backport streams), CPE product collisions (`wire` Go generator vs Wire messenger), platform-specific code (Windows-only Python paths) — record them and propose a scanner fix: cross-validate each Grype finding against OSV affected-ranges with the installed version before issue creation, and flag findings whose advisory CPE product does not match the derivation pname. File it as an issue against `scripts/vulnerability/` with concrete issue numbers as evidence.
