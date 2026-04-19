# Miniflux Summarizer — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy miniflux-summarizer on mokosh as 4 scheduled systemd services with secret injection.

**Architecture:** NixOS module builds JSON config template at eval time (prompts from .md files, API keys as PLACEHOLDER). At runtime, systemd LoadCredential + jq injects secrets. 4 timers: morning (09:00 MSK), evening (21:00 MSK), weekly (Sun 09:00 MSK), monthly (1st 09:00 MSK).

**Tech Stack:** NixOS module system, systemd services/timers, jq, miniflux-summarizer Python CLI (from flake input).

**Verification:** `make setup-dummy-secrets && make check` after each task. `nixfmt .` for formatting.

---

### Task 1: Create directory structure and prompt files

**Files:**
- Create: `roles/reading/rss/default.nix`
- Create: `roles/reading/rss/miniflux.nix`
- Create: `roles/reading/rss/summarizer/prompts/daily.md`
- Create: `roles/reading/rss/summarizer/prompts/weekly.md`
- Create: `roles/reading/rss/summarizer/prompts/monthly.md`
- Create: `roles/reading/rss/summarizer/service.nix` (empty shell)
- Delete: `roles/reading/rss.nix`

**Step 1: Create directory structure**

```bash
mkdir -p roles/reading/rss/summarizer/prompts
```

**Step 2: Move rss.nix → miniflux.nix**

Copy `roles/reading/rss.nix` to `roles/reading/rss/miniflux.nix` (content unchanged, the module defines `options.roles.rss` which stays the same). Then delete `roles/reading/rss.nix`.

**Step 3: Create daily.md**

Copy content from `/Users/o__ni/Code/Git/miniflux-summarizer/prompt.md` → `roles/reading/rss/summarizer/prompts/daily.md`.

This is the daily digest system prompt (35 lines). It instructs the LLM to:
- Write an executive summary (1-2 sentences)
- Merge duplicate/related news
- Use dynamic categorisation with emojis
- Use Markdown hyperlinks (never raw URLs)
- Sort by importance within categories
- Always output in English
- Keep 1-2 sentences per news item

**Step 4: Create weekly.md**

Copy content from `/Users/o__ni/Code/Git/miniflux-summarizer/weekly_prompt.md` → `roles/reading/rss/summarizer/prompts/weekly.md`.

This is the weekly newsletter system prompt (44 lines). It instructs the LLM to:
- Write a weekly executive summary (2-3 sentences)
- Merge stories across days (never repeat)
- Use broader categories than daily
- Optionally include "Trend of the Week" section
- Target 500-1500 words

**Step 5: Create monthly.md**

New monthly newsletter prompt following the weekly style but adapted for monthly scope. Key differences from weekly:
- Executive summary covers the dominant theme(s) of the month
- Merge stories across weeks, tracking evolution over 4+ weeks
- Broader categories (macro-level)
- "Trend of the Month" section
- Longer target length: 1000-3000 words
- Include a "Month in Review" narrative

**Step 6: Create service.nix shell**

Empty NixOS module shell:

```nix
{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.roles.rss.summarizer;
in
{
  options.roles.rss.summarizer = {
    enable = mkEnableOption "Miniflux RSS Summarizer";
  };

  config = mkIf cfg.enable {
  };
}
```

**Step 7: Create default.nix coordinator**

```nix
{ config, lib, pkgs, ... }:
{
  imports = [
    ./miniflux.nix
    ./summarizer/service.nix
  ];
}
```

**Step 8: Verify**

```bash
make setup-dummy-secrets && make check
```

Expected: passes (rss.nix deleted but rss/default.nix provides same `roles.rss` option via import).

**Step 9: Commit**

```bash
git add -A roles/reading/rss/ roles/reading/rss.nix
git commit -m "feat(rss): create directory structure and prompt files"
```

---

### Task 2: Add miniflux-summarizer flake input

**Files:**
- Modify: `flake.nix`

**Step 1: Add input to flake.nix**

In the `inputs` block, add:

```nix
miniflux-summarizer.url = "github:wellWINeo/miniflux-summarizer";
```

**Step 2: Verify**

```bash
make check
```

Expected: passes. The input is declared but not yet consumed.

**Step 3: Commit**

```bash
git add flake.nix
git commit -m "feat(flake): add miniflux-summarizer input"
```

---

### Task 3: Implement summarizer service module

**Files:**
- Modify: `roles/reading/rss/summarizer/service.nix`

**Step 1: Write full service.nix**

The module needs:

**Options:**
```nix
options.roles.rss.summarizer = {
  enable = mkEnableOption "Miniflux RSS Summarizer";
  llmApiKeyFile = mkOption { type = types.str; };
  minifluxApiKeyFile = mkOption { type = types.str; };
  dailyTargetFeedId = mkOption { type = types.int; };
  weeklySourceFeedId = mkOption { type = types.int; default = cfg.dailyTargetFeedId; };
  weeklyTargetFeedId = mkOption { type = types.int; };
  monthlySourceFeedId = mkOption { type = types.int; default = cfg.weeklyTargetFeedId; };
  monthlyTargetFeedId = mkOption { type = types.int; };
};
```

Note: `cfg` refers to `config.roles.rss.summarizer`. For defaults that reference other options of the same module, use the full path or handle carefully.

**Config template (eval time):**

```nix
let
  dailyPrompt = builtins.readFile ./prompts/daily.md;
  weeklyPrompt = builtins.readFile ./prompts/weekly.md;
  monthlyPrompt = builtins.readFile ./prompts/monthly.md;

  configTemplate = {
    miniflux = {
      base_url = "https://rss.${config.roles.rss.baseDomain}";
      api_key = "PLACEHOLDER";
    };
    llm = {
      model = "x-ai/grok-4.1-fast";
      base_url = "https://openrouter.ai/api/v1";
      api_key = "PLACEHOLDER";
    };
    agents = {
      tech-daily = {
        source = "raw_entries";
        target_feed_id = cfg.dailyTargetFeedId;
        prompt = dailyPrompt;
        ignore = [
          { type = "subject"; value = "Sponsored"; }
          { type = "feed_id"; value = "6"; }
          { type = "category_id"; value = "3"; }
          { type = "category_id"; value = "4"; }
        ];
        presets = {
          daily-morning = { title = "Daily morning digest for {{date}}"; from = "-12h"; to = null; };
          daily-evening = { title = "Daily evening digest for {{date}}"; from = "-12h"; to = null; };
        };
      };
      tech-weekly = {
        source = "digests";
        source_feed_id = cfg.weeklySourceFeedId;
        target_feed_id = cfg.weeklyTargetFeedId;
        prompt = weeklyPrompt;
        ignore = [];
        presets = {
          weekly = { title = "Weekly tech newsletter for {{date}}"; from = "-7d"; to = null; };
        };
      };
      tech-monthly = {
        source = "digests";
        source_feed_id = cfg.monthlySourceFeedId;
        target_feed_id = cfg.monthlyTargetFeedId;
        prompt = monthlyPrompt;
        ignore = [];
        presets = {
          monthly = { title = "Monthly tech newsletter for {{date}}"; from = "-30d"; to = null; };
        };
      };
    };
  };

  templateFile = pkgs.writeText "summarizer-config-template.json" (builtins.toJSON configTemplate);
in
```

**systemd services (4 total):**

Each follows this pattern (example for morning):

```nix
systemd.services.miniflux-summarizer-morning = {
  description = "Miniflux Summarizer — Morning Digest";
  path = [ pkgs.miniflux-summarizer pkgs.jq ];
  serviceConfig = {
    Type = "oneshot";
    PrivateTmp = true;
    LoadCredential = [
      "llm-api-key:${cfg.llmApiKeyFile}"
      "miniflux-api-key:${cfg.minifluxApiKeyFile}"
    ];
  };
  script = ''
    cat ${templateFile} \
      | jq --arg llm_key "$(cat "$CREDENTIALS_DIRECTORY/llm-api-key")" \
           --arg mf_key "$(cat "$CREDENTIALS_DIRECTORY/miniflux-api-key")" \
           '.llm.api_key = $llm_key | .miniflux.api_key = $mf_key' \
      > /tmp/summarizer-config.json
    exec miniflux-summarizer \
      --config /tmp/summarizer-config.json \
      --agent tech-daily \
      --preset daily-morning
  '';
};
```

**systemd timers (4 total):**

```nix
systemd.timers.miniflux-summarizer-morning = {
  wantedBy = [ "timers.target" ];
  timerConfig = {
    OnCalendar = "*-*-* 06:00:00 UTC";   # 09:00 MSK
    Persistent = true;
  };
};

systemd.timers.miniflux-summarizer-evening = {
  wantedBy = [ "timers.target" ];
  timerConfig = {
    OnCalendar = "*-*-* 18:00:00 UTC";   # 21:00 MSK
    Persistent = true;
  };
};

systemd.timers.miniflux-summarizer-weekly = {
  wantedBy = [ "timers.target" ];
  timerConfig = {
    OnCalendar = "Sun *-*-* 06:00:00 UTC"; # Sun 09:00 MSK
    Persistent = true;
  };
};

systemd.timers.miniflux-summarizer-monthly = {
  wantedBy = [ "timers.target" ];
  timerConfig = {
    OnCalendar = "*-*-01 06:00:00 UTC";    # 1st 09:00 MSK
    Persistent = true;
  };
};
```

The evening service uses `--preset daily-evening`, weekly uses `--agent tech-weekly --preset weekly`, monthly uses `--agent tech-monthly --preset monthly`.

**Important:** `pkgs.miniflux-summarizer` comes from the overlay added in Task 4 (mokosh machine config). The service module references it, and it must be available. Add `assertions` or let nix eval fail naturally if the package is missing.

**Step 2: Verify**

```bash
make check
```

This will fail because `pkgs.miniflux-summarizer` doesn't exist yet (overlay not added until Task 4). That's expected. The module itself is correct; it just needs the package. We verify full eval after Task 4.

Alternative: wrap the package reference so it fails gracefully, or use `mkOption` for the package. Simplest: just let it fail now and fix in Task 4.

**Step 3: Commit**

```bash
git add roles/reading/rss/summarizer/service.nix
git commit -m "feat(rss/summarizer): implement service module with systemd timers"
```

---

### Task 4: Wire up mokosh config

**Files:**
- Modify: `machines/mokosh/default.nix`

**Step 1: Add overlay for miniflux-summarizer package**

In mokosh's module list in `flake.nix`, add an overlay (same pattern as veles with telemt). The overlay needs access to the flake input, so it must be in the module list where `inputs` are available via `specialArgs`.

Wait — `specialArgs = inputs` is already set for all machines in flake.nix. So `inputs` is available as a module argument. Add overlay in mokosh's modules list in `flake.nix`:

```nix
# In nixosConfigurations.mokosh modules array, add:
{
  nixpkgs.overlays = (import ./overlays) ++ [
    (final: prev: {
      miniflux-summarizer = inputs.miniflux-summarizer.packages.${prev.stdenv.hostPlatform.system}.default;
    })
  ];
}
```

Actually, better approach: add the overlay directly in `machines/mokosh/default.nix` since it has access to `inputs` via `specialArgs`:

```nix
{ lib, inputs, ... }:
# add to existing let block or nixpkgs.overlays in config
```

But `nixpkgs.overlays` needs to be set before pkgs is evaluated. The cleanest way is adding it to the modules list in `flake.nix` (like veles). Let's follow the existing pattern.

**Step 2: Update import path**

Change:
```nix
../../roles/reading/rss.nix
```
To:
```nix
../../roles/reading/rss
```

**Step 3: Add summarizer config**

```nix
roles.rss.summarizer = {
  enable = true;
  llmApiKeyFile = "/etc/nixos/secrets/miniflux-llm-api-key";
  minifluxApiKeyFile = "/etc/nixos/secrets/miniflux-api-key";
  dailyTargetFeedId = 57;
  weeklySourceFeedId = 57;
  weeklyTargetFeedId = 58;
  monthlySourceFeedId = 58;
  monthlyTargetFeedId = 59;
};
```

**Step 4: Verify**

```bash
make setup-dummy-secrets && make check
```

Expected: passes. Full eval including service.nix, overlay, timers.

**Step 5: Commit**

```bash
git add flake.nix machines/mokosh/default.nix
git commit -m "feat(mokosh): enable miniflux-summarizer with scheduled jobs"
```

---

### Task 5: Add secret file entries

**Files:**
- Modify: `secrets/unlocked/spec.txt`

**Step 1: Add entries**

Append to `secrets/unlocked/spec.txt`:

```
mokosh:miniflux-llm-api-key:0400:root:root
mokosh:miniflux-api-key:0400:root:root
```

**Step 2: Commit**

```bash
git add secrets/unlocked/spec.txt
git commit -m "chore(secrets): add miniflux-summarizer secret spec entries"
```

---

### Task 6: Final verification and formatting

**Step 1: Format all changed files**

```bash
nixfmt .
```

**Step 2: Verify**

```bash
make setup-dummy-secrets && make check
```

**Step 3: Review**

```bash
git diff main
```

Review for: correct timer schedules, correct jq paths, correct agent/preset names, prompts properly injected, secret paths match spec.txt.

**Step 4: Final commit if formatting changes**

```bash
git add -A
git commit -m "style: format nix files"
```
