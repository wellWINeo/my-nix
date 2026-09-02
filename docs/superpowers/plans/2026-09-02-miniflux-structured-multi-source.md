# Miniflux Structured Multi-Source Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (or superpowers:subagent-driven-development) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update the mokosh RSS summarizer configuration to the merged upstream structured multi-source schema at revision `4d9bf3d5bb2315e65d68cfa3bc87aa08e27aca04`.

**Architecture:** Use the upstream miniflux-summarizer package directly, without the temporary local patch overlay. Generate agents with the required `sources` list: raw all/category sources for daily agents and explicit feed sources for newsletter agents; keep generated-digest exclusion explicit for raw daily agents and expose the resulting template through the existing Nix validation check.

**Tech Stack:** Nix flakes/lock metadata, NixOS modules, systemd service/timer configuration, Nix assertions.

**Spec:** User request in this conversation: migrate this repository to the merged structured multi-source miniflux-summarizer PR.

## Global Constraints

- Pin `miniflux-summarizer` to upstream merge commit `4d9bf3d5bb2315e65d68cfa3bc87aa08e27aca04` with generated lock metadata.
- Remove `roles/reading/rss/summarizer/category-filter.patch` and the overlay `overrideAttrs` patching.
- Use `sources` with only `all`, `category`, and `feed` kinds as required by upstream.
- Preserve existing schedules and prompt files.
- Do not modify any secrets or secret values.

---

### Task 1: Add the failing structured-source validation

**Files:**
- Modify: `roles/reading/rss/summarizer/validation.nix`

**Interfaces:**
- Consumes: `config.roles.rss.summarizer._configTemplate`.
- Produces: assertions for the required `sources` mappings and explicit `generated_digests` rules.

- [x] **Step 1: Replace legacy validation fields with new expectations**

Replace the `expectedInclude` binding and the assertions on `source` and `include` with these checks:

```nix
  expectedGeneratedDigests = { type = "generated_digests"; };
  validation =
    assert bloomberg.sources == [
      {
        kind = "category";
        id = 4;
      }
    ];
    assert technical.sources == [ { kind = "all"; } ];
    assert builtins.elem expectedGeneratedDigests bloomberg.ignore;
```

Also assert the weekly and monthly agents each have a single `feed` source with their configured IDs, while retaining prompt, service, and timer assertions.

- [x] **Step 2: Run the validation check to verify it fails for the old template**

Run:

```bash
nix build --no-link 'path:.#checks.x86_64-linux.miniflux-summarizer-bloomberg'
```

Expected: evaluation fails because the current template still exposes legacy `source`/`include` fields and lacks the required structured `sources` values.

---

### Task 2: Migrate the service template

**Files:**
- Modify: `roles/reading/rss/summarizer/service.nix`

**Interfaces:**
- Consumes: Existing module options, prompts, target/source feed IDs, and schedules.
- Produces: JSON config compatible with upstream commit `4d9bf3d5`.

- [x] **Step 1: Convert the daily agent source fields**

Set `tech-daily.sources = [ { kind = "all"; } ]`, remove its `source` field, and append `{ type = "generated_digests"; }` to its existing ignore list without changing the existing subject/feed/category rules.

- [x] **Step 2: Convert the Bloomberg agent filters**

Set `bloomberg-daily.sources = [ { kind = "category"; id = 4; } ]`, remove the legacy `source` and `include` fields, and append the value-less `generated_digests` ignore rule to the existing Sponsored/feed-6 rules.

- [x] **Step 3: Convert newsletter agents to feed sources**

Set `tech-weekly.sources = [ { kind = "feed"; id = cfg.weeklySourceFeedId; } ]` and `tech-monthly.sources = [ { kind = "feed"; id = cfg.monthlySourceFeedId; } ]`; remove both legacy `source` and `source_feed_id` fields.

- [x] **Step 4: Run formatting and the focused validation**

Run:

```bash
nixfmt roles/reading/rss/summarizer/service.nix roles/reading/rss/summarizer/validation.nix
nix build --no-link 'path:.#checks.x86_64-linux.miniflux-summarizer-bloomberg'
```

Expected: the focused check evaluates successfully.

---

### Task 3: Remove the temporary patch overlay and pin upstream

**Files:**
- Modify: `flake.nix`
- Modify: `flake.lock`
- Delete: `roles/reading/rss/summarizer/category-filter.patch`

**Interfaces:**
- Consumes: Upstream package at the exact merged revision.
- Produces: `pkgs.miniflux-summarizer` directly from `inputs.miniflux-summarizer`.

- [x] **Step 1: Remove overrideAttrs patching**

Replace the mokosh overlay entry with the direct upstream package assignment:

```nix
miniflux-summarizer =
  inputs.miniflux-summarizer.packages.${prev.stdenv.hostPlatform.system}.default;
```

- [x] **Step 2: Delete the obsolete patch**

Delete `roles/reading/rss/summarizer/category-filter.patch`; do not alter secrets.

- [x] **Step 3: Regenerate only the miniflux-summarizer lock node**

Run:

```bash
nix flake lock --update-input miniflux-summarizer
```

Because the upstream default branch is the requested merge revision, this updates the node to the requested commit. If Nix cannot access its daemon, verify the commit timestamp and NAR hash from an exact Git archive, then update only this node with those values.

---

### Task 4: Format, verify, inspect, commit, and push

**Files:**
- Modify only files from Tasks 1–3 plus the already-present Bloomberg prompt and validation changes.

- [x] **Step 1: Format changed Nix files**

Run:

```bash
nixfmt flake.nix roles/reading/rss/summarizer/service.nix roles/reading/rss/summarizer/validation.nix
```

- [x] **Step 2: Run repository checks**

Run (using the repository's existing decrypted secrets file; do not create or modify secret files):

```bash
make check
```

If the Nix daemon is inaccessible, record the exact failure and run all available local syntax/diff checks without claiming a successful flake check.

- [x] **Step 3: Inspect requirements and diff**

Verify with `git diff`, `git status --short`, and targeted searches that:
- the patch file is gone;
- no `overrideAttrs`, `source_feed_id`, singular `source`, or `include` remains in the migrated template/overlay;
- the lock node uses the requested revision;
- schedules, prompts, and secret files are unchanged.

- [x] **Step 4: Commit the complete migration**

Run:

```bash
git add flake.nix flake.lock roles/reading/rss/summarizer
git commit -m "feat(rss): migrate summarizer to structured sources"
```

- [x] **Step 5: Push the requested branch**

Run:

```bash
git push -u origin feat/bloomberg-multi-source
```

Report the commit ID, push result, verification evidence, and any daemon limitation honestly.
