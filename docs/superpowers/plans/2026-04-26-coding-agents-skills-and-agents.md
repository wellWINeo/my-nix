# Coding-Agent Skills & Agents Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `home/coding-agents/` to manage three asset classes (instructions, skills, agents) with a per-tool option tree (`codingAgents.<tool>.{enable,instructions,skills,agents}`). Skills use the upstream `agent-skills-nix` flake; agents are bespoke with per-file `targets` lists.

**Architecture:** The existing `home/coding-agents/{default.nix, AGENTS.md}` migrates into `instructions/`. A new umbrella `default.nix` declares the option tree. Two new sub-modules — `skills/` (a thin wrapper around `programs.agent-skills`) and `agents/` (a ~30-line bespoke module) — consume the per-tool flags. `agent-skills-nix` is added as a flake input and threaded through `extraSpecialArgs`.

**Tech Stack:** Nix flakes, home-manager (release-25.11), `agent-skills-nix` (`github:Kyure-A/agent-skills-nix`), `nixfmt-rfc-style`.

**Spec:** `docs/superpowers/specs/2026-04-26-coding-agents-skills-and-agents-design.md`

**Branch:** `feat/coding-agents-skills-and-agents` (already created and checked out by the brainstorming session that wrote this plan).

---

## File Structure

| File                                            | Action  | Responsibility                                                                  |
|-------------------------------------------------|---------|---------------------------------------------------------------------------------|
| `home/coding-agents/default.nix`                | replace | Umbrella: full option tree + imports of three sub-modules                       |
| `home/coding-agents/instructions/default.nix`   | create  | CLAUDE.md / opencode AGENTS.md wiring (consumes new option paths)               |
| `home/coding-agents/instructions/AGENTS.md`     | move    | Existing source of truth; content unchanged                                     |
| `home/coding-agents/agents/default.nix`         | create  | Walks `definitions`, deploys `home.file` per `(definition, target)` pair        |
| `home/coding-agents/agents/own/.gitkeep`        | create  | Placeholder so `agents/own/` exists in the repo with no committed agents        |
| `home/coding-agents/skills/default.nix`         | create  | Wraps `programs.agent-skills`; declares custom opencode target; routes options  |
| `home/coding-agents/skills/own/.gitkeep`        | create  | Placeholder so `skills/own/` exists                                             |
| `flake.nix`                                     | modify  | Add `agent-skills` input; add `extraSpecialArgs` + HM module to both macOS hosts |

No automated tests for Nix code — validation is `nix flake check`, `nix eval` on option paths, and inspecting the activation package. Each task ends with a build/check that proves the change works.

**Verification pattern:** Tasks 2 and 3 land sub-modules whose effect on a host with empty inputs (no agent definitions, empty skills allowlist) is invisible. To verify the wiring really works, those tasks include an inline smoke test that *temporarily* adds a sample agent / skill, builds, inspects the activation package, then **reverts the smoke test before committing**. The committed state has empty `own/` directories and no example content.

---

## Task 1: Migrate `instructions/` and add umbrella with new option tree

Move `home/coding-agents/{default.nix, AGENTS.md}` into `home/coding-agents/instructions/`, create the new umbrella `default.nix` declaring the full option tree, and adapt `instructions/default.nix` to read the new option paths. Add placeholder stubs at `home/coding-agents/{agents,skills}/default.nix` so the umbrella's `imports` evaluates successfully — Tasks 2 and 3 replace them with real content.

After this task, on existing hosts the deployed file set is identical to today (`~/.claude/CLAUDE.md` and `~/.config/opencode/AGENTS.md` still symlink to the migrated `AGENTS.md`).

**Files:**
- Move: `home/coding-agents/AGENTS.md` → `home/coding-agents/instructions/AGENTS.md`
- Replace: `home/coding-agents/default.nix` (becomes the umbrella)
- Create: `home/coding-agents/instructions/default.nix`
- Create: `home/coding-agents/agents/default.nix` (placeholder stub)
- Create: `home/coding-agents/skills/default.nix` (placeholder stub)
- Create: `home/coding-agents/agents/own/.gitkeep`
- Create: `home/coding-agents/skills/own/.gitkeep`

- [ ] **Step 1: Create new directories and move `AGENTS.md`**

```bash
mkdir -p home/coding-agents/instructions \
         home/coding-agents/agents/own \
         home/coding-agents/skills/own
git mv home/coding-agents/AGENTS.md home/coding-agents/instructions/AGENTS.md
touch home/coding-agents/agents/own/.gitkeep \
      home/coding-agents/skills/own/.gitkeep
```

Expected: `git status` shows `AGENTS.md` renamed and two `.gitkeep` files added (untracked).

- [ ] **Step 2: Replace `home/coding-agents/default.nix` with the umbrella**

Overwrite `home/coding-agents/default.nix` with exactly:

```nix
{ lib, config, ... }:

let
  cfg = config.codingAgents;

  toolOpts = parentEnable: {
    enable = lib.mkEnableOption "asset deployment for this coding-agent tool";
    instructions = lib.mkOption {
      type = lib.types.bool;
      default = parentEnable;
      description = "Deploy global instructions (CLAUDE.md / AGENTS.md) for this tool.";
    };
    skills = lib.mkOption {
      type = lib.types.bool;
      default = parentEnable;
      description = "Deploy the skills bundle for this tool.";
    };
    agents = lib.mkOption {
      type = lib.types.bool;
      default = parentEnable;
      description = "Deploy registered agent files for this tool.";
    };
  };
in
{
  imports = [
    ./instructions
    ./agents
    ./skills
  ];

  options.codingAgents = {
    claude = toolOpts cfg.claude.enable;
    opencode = toolOpts cfg.opencode.enable;
  };
}
```

This file declares only options; no `config` block. Behavior is delegated to the three imported sub-modules.

- [ ] **Step 3: Write `home/coding-agents/instructions/default.nix`**

Write to `home/coding-agents/instructions/default.nix` exactly:

```nix
{ lib, config, ... }:

let
  cfg = config.codingAgents;
  enableClaude = cfg.claude.enable && cfg.claude.instructions;
  enableOpencode = cfg.opencode.enable && cfg.opencode.instructions;
in
{
  config = {
    home.file.".claude/CLAUDE.md" = lib.mkIf enableClaude {
      source = ./AGENTS.md;
    };
    home.file.".config/opencode/AGENTS.md" = lib.mkIf enableOpencode {
      source = ./AGENTS.md;
    };
  };
}
```

This is structurally identical to today's `home/coding-agents/default.nix` except (a) the source path is `./AGENTS.md` (now in the same directory after the move) and (b) it gates on `<tool>.enable && <tool>.instructions` instead of just `<tool>.enable`. Because `<tool>.instructions` defaults to `<tool>.enable`, hosts that only set `<tool>.enable = true;` keep the same behavior.

- [ ] **Step 4: Write the placeholder `agents/default.nix` and `skills/default.nix` stubs**

Write to `home/coding-agents/agents/default.nix`:

```nix
{ ... }:
{
  # Placeholder. Real implementation lands in Task 2.
}
```

Write to `home/coding-agents/skills/default.nix`:

```nix
{ ... }:
{
  # Placeholder. Real implementation lands in Task 3.
}
```

These are valid no-op modules so the umbrella's `imports` evaluates.

- [ ] **Step 5: Format**

```bash
nix develop --command nixfmt \
  home/coding-agents/default.nix \
  home/coding-agents/instructions/default.nix \
  home/coding-agents/agents/default.nix \
  home/coding-agents/skills/default.nix
```

Expected: exit 0. Files are reformatted to RFC style (small whitespace adjustments are fine).

- [ ] **Step 6: Set up dummy secrets if needed**

```bash
test -f secrets/secrets.json || make setup-dummy-secrets
```

Expected: file exists either way; the command is a no-op if real secrets are already unlocked.

- [ ] **Step 7: Eval-check the new option tree**

```bash
nix eval 'path:.#homeConfigurations."o__ni@Stepans-MacBook-Pro".config.codingAgents.claude.instructions'
```

Expected output: `true` (because `codingAgents.claude.enable = true` is set in `flake.nix`, and `claude.instructions` defaults to `claude.enable`).

```bash
nix eval 'path:.#homeConfigurations."o__ni@Stepans-MacBook-Pro".config.codingAgents.claude.skills'
```

Expected output: `true` (same reason). Skills aren't actually deployed yet — Task 3 implements that — but the option exists and resolves correctly.

If either `eval` errors with `attribute … missing`, the umbrella isn't loaded — re-check Step 2 and that `home/default.nix` already imports `./coding-agents` (it does, from the previous coding-agents-md feature; no edit needed here).

- [ ] **Step 8: Build the activation package and verify instructions still deploy**

```bash
nix build 'path:.#homeConfigurations."o__ni@Stepans-MacBook-Pro".activationPackage' --no-link --print-out-paths
```

Expected: prints a `/nix/store/...-home-manager-generation` path; exit 0.

```bash
ACT=$(nix build 'path:.#homeConfigurations."o__ni@Stepans-MacBook-Pro".activationPackage' --no-link --print-out-paths)
find "$ACT/home-files" -name 'CLAUDE.md' -o -name 'AGENTS.md'
```

Expected output: two paths printed —
- `<store>/home-files/.claude/CLAUDE.md`
- `<store>/home-files/.config/opencode/AGENTS.md`

```bash
head -3 "$ACT/home-files/.claude/CLAUDE.md"
```

Expected: starts with `# AGENTS.md`. (The migrated file's content is unchanged.)

- [ ] **Step 9: Commit**

```bash
git add home/coding-agents/default.nix \
        home/coding-agents/instructions/default.nix \
        home/coding-agents/instructions/AGENTS.md \
        home/coding-agents/agents/default.nix \
        home/coding-agents/agents/own/.gitkeep \
        home/coding-agents/skills/default.nix \
        home/coding-agents/skills/own/.gitkeep
git commit -m "$(cat <<'EOF'
refactor(home/coding-agents): umbrella module with per-tool option tree

Migrates instructions/AGENTS.md into home/coding-agents/instructions/ and
broadens codingAgents.<tool>.enable into a per-tool tree with sub-flags
{instructions, skills, agents}. Sub-flags default to the parent's enable
value, so existing host configs keep their current behavior.

skills/ and agents/ ship as placeholder stubs in this commit; real
implementations land in follow-up commits.
EOF
)"
```

Expected: clean commit on `feat/coding-agents-skills-and-agents`. Per the global AGENTS.md, do NOT add a `Co-Authored-By` trailer.

---

## Task 2: Implement the `agents/` sub-module

Replace the placeholder `home/coding-agents/agents/default.nix` with the real implementation. Add an `agents.definitions` option (attrset of `{ source, targets }` submodules) and a `config` block that emits `home.file` entries per `(definition, target)` pair, gated on per-host enable flags. After this task, no agents are registered yet (the `definitions` attrset is empty by default), so the deployed file set is unchanged from Task 1. The smoke test in Step 3 verifies the module actually emits files when definitions exist.

**Files:**
- Replace: `home/coding-agents/agents/default.nix`

- [ ] **Step 1: Write the real module**

Overwrite `home/coding-agents/agents/default.nix` with exactly:

```nix
{ lib, config, ... }:

let
  cfg = config.codingAgents;

  targetPaths = {
    claude = name: ".claude/agents/${name}.md";
    opencode = name: ".config/opencode/agents/${name}.md";
  };

  isTargetEnabled = target: cfg.${target}.enable && cfg.${target}.agents;

  expandDefinition =
    name: def:
    let
      activeTargets = lib.filter (
        t: builtins.elem t def.targets && isTargetEnabled t
      ) (lib.attrNames targetPaths);
    in
    lib.listToAttrs (
      map (t: {
        name = targetPaths.${t} name;
        value = { source = def.source; };
      }) activeTargets
    );

  expandedFiles = lib.foldl' (
    acc: name: acc // expandDefinition name cfg.agents.definitions.${name}
  ) { } (lib.attrNames cfg.agents.definitions);
in
{
  options.codingAgents.agents.definitions = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          source = lib.mkOption {
            type = lib.types.path;
            description = "Path to the agent's .md source file.";
          };
          targets = lib.mkOption {
            type = lib.types.listOf (lib.types.enum [ "claude" "opencode" ]);
            default = [ "claude" "opencode" ];
            description = "Coding-agent tools that should receive this agent.";
          };
        };
      }
    );
    default = { };
    description = "Registered agent files. Each entry is deployed to its declared targets.";
  };

  config.home.file = expandedFiles;
}
```

Notes for the executing engineer:
- The `targetPaths` attrset is the single source of truth for "what coding-agent tools exist and where their agent files go". Adding a third tool later means adding a row here plus extending the umbrella's `toolOpts` call.
- `expandedFiles` produces an attrset keyed by *destination path* (e.g. `".claude/agents/foo.md"`) with `{ source = ...; }` values — the shape `home.file` expects.
- The `config.home.file = expandedFiles;` line uses the top-level `config.<x>` shorthand (Nix module system merges this with other modules' `config` assignments).

- [ ] **Step 2: Format and eval-check**

```bash
nix develop --command nixfmt home/coding-agents/agents/default.nix
```

Expected: exit 0.

```bash
nix eval 'path:.#homeConfigurations."o__ni@Stepans-MacBook-Pro".config.codingAgents.agents.definitions' --json
```

Expected output: `{}` (empty attrset; the option exists with its default).

- [ ] **Step 3: Smoke-test agent deployment with a temporary registration**

The committed module is a no-op until someone registers an agent. Verify deployment works by temporarily registering one and inspecting the activation package. **Revert in Step 4 before committing.**

Create a temp source file:

```bash
cat > home/coding-agents/agents/own/_smoke.md <<'EOF'
---
name: smoke
description: Temporary smoke-test agent for plan Task 2 — delete me.
mode: subagent
---

Verify that home-manager deploys this file to both Claude Code and opencode paths.
EOF
```

Append a smoke registration block to `home/coding-agents/agents/default.nix`. Open the file and immediately *before* the final closing `}` (i.e. inside the module body, after `config.home.file = expandedFiles;`), insert:

```nix

  # SMOKE-TEST: revert before commit (plan Task 2 Step 4).
  config.codingAgents.agents.definitions._smoke = {
    source = ./own/_smoke.md;
    targets = [ "claude" "opencode" ];
  };
```

The Nix module system merges this `config.codingAgents.agents.definitions._smoke` assignment with the existing `config.home.file = expandedFiles;` (both are `config.*` paths and merge cleanly).

Build and verify:

```bash
nix develop --command nixfmt home/coding-agents/agents/default.nix
ACT=$(nix build 'path:.#homeConfigurations."o__ni@Stepans-MacBook-Pro".activationPackage' --no-link --print-out-paths)
find "$ACT/home-files" -path '*/agents/_smoke.md'
```

Expected output: two paths —
- `<store>/home-files/.claude/agents/_smoke.md`
- `<store>/home-files/.config/opencode/agents/_smoke.md`

Verify content:

```bash
head -2 "$ACT/home-files/.claude/agents/_smoke.md"
```

Expected: `---` followed by `name: smoke`.

If only one path appears (or none), the gating logic in `isTargetEnabled` is wrong — re-check Step 1.

- [ ] **Step 4: Revert the smoke-test changes**

```bash
rm home/coding-agents/agents/own/_smoke.md
```

Open `home/coding-agents/agents/default.nix` and remove the smoke block — the entire comment line plus the `config.codingAgents.agents.definitions._smoke = { ... };` assignment that was added in Step 3. The file should match what was written in Step 1.

Verify the revert:

```bash
git diff home/coding-agents/agents/default.nix
```

Expected: only the differences relative to the placeholder from Task 1 — no `_smoke` references. If `git diff` shows `_smoke` anywhere, the revert is incomplete.

```bash
test -f home/coding-agents/agents/own/_smoke.md && echo "STILL PRESENT" || echo "removed"
```

Expected: `removed`.

Re-run the build to confirm the activation package no longer contains `_smoke`:

```bash
ACT=$(nix build 'path:.#homeConfigurations."o__ni@Stepans-MacBook-Pro".activationPackage' --no-link --print-out-paths)
find "$ACT/home-files" -path '*_smoke*' || echo "no smoke artifacts"
```

Expected: `no smoke artifacts` (the `find` exits non-zero when nothing matches; the `||` clause prints the confirmation).

- [ ] **Step 5: Commit**

```bash
git add home/coding-agents/agents/default.nix
git commit -m "$(cat <<'EOF'
feat(home/coding-agents): implement agents sub-module

Adds codingAgents.agents.definitions: an attrset of { source, targets }
that emits home.file entries per (definition, target) pair. Per-target
deployment is gated on codingAgents.<tool>.{enable,agents}.

No agents are registered in this commit; the framework is empty until
own agent files are added in follow-up commits.
EOF
)"
```

Expected: clean commit, only `home/coding-agents/agents/default.nix` modified.

---

## Task 3: Implement the `skills/` sub-module + flake plumbing

Add `agent-skills-nix` as a flake input, wire it into both macOS `homeConfigurations.*` entries (HM module + `extraSpecialArgs`), and replace the placeholder `home/coding-agents/skills/default.nix` with the real wrapper around `programs.agent-skills`. After this task, the deployed file set is still unchanged for existing hosts (empty allowlist + empty `own/` = no skills deployed). The smoke test in Step 4 verifies the wiring works end-to-end.

**Files:**
- Modify: `flake.nix` (add input + wire HM module + `extraSpecialArgs` on both hosts)
- Replace: `home/coding-agents/skills/default.nix`

- [ ] **Step 1: Add `agent-skills` to `flake.nix` inputs**

In `flake.nix`, the current `inputs` block is at lines 4–13:

```nix
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    miniflux-summarizer.url = "github:wellWINeo/miniflux-summarizer";
  };
```

Add an `agent-skills` entry that follows `nixpkgs` (to match the project's pattern of pinning transitive nixpkgs):

```nix
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    miniflux-summarizer.url = "github:wellWINeo/miniflux-summarizer";
    agent-skills = {
      url = "github:Kyure-A/agent-skills-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
```

- [ ] **Step 2: Wire `agent-skills` HM module + `extraSpecialArgs` into both macOS hosts**

Locate the two `homeConfigurations.*` entries in `flake.nix` (currently at approximately lines 92–118 — `o__ni@Stepans-MacBook-Pro` and `o__ni@DodoBook.local`). Each currently looks like:

```nix
      homeConfigurations."o__ni@Stepans-MacBook-Pro" = inputs.home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgsFor.aarch64-darwin;
        modules = [
          ./home
          {
            software.alacritty.enable = true;
            software.alacritty.theme = "one-dark";
            software.neovim.enable = true;
            codingAgents.claude.enable = true;
            codingAgents.opencode.enable = true;
          }
        ];
      };
```

Change each entry to add `extraSpecialArgs = { inherit inputs; };` and prepend `inputs.agent-skills.homeManagerModules.default` to the `modules` list. The Stepans entry becomes:

```nix
      homeConfigurations."o__ni@Stepans-MacBook-Pro" = inputs.home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgsFor.aarch64-darwin;
        extraSpecialArgs = { inherit inputs; };
        modules = [
          inputs.agent-skills.homeManagerModules.default
          ./home
          {
            software.alacritty.enable = true;
            software.alacritty.theme = "one-dark";
            software.neovim.enable = true;
            codingAgents.claude.enable = true;
            codingAgents.opencode.enable = true;
          }
        ];
      };
```

Apply the same two additions (`extraSpecialArgs` line + `inputs.agent-skills.homeManagerModules.default` as the first list item) to the `o__ni@DodoBook.local` entry. Do not change anything else in that entry (theme stays `one-half-light`, the rest unchanged).

- [ ] **Step 3: Replace `home/coding-agents/skills/default.nix` with the real wrapper**

Overwrite `home/coding-agents/skills/default.nix` with exactly:

```nix
{ lib, config, ... }:

let
  cfg = config.codingAgents;

  claudeEnabled = cfg.claude.enable && cfg.claude.skills;
  opencodeEnabled = cfg.opencode.enable && cfg.opencode.skills;
  anyTargetEnabled = claudeEnabled || opencodeEnabled;
  hasAllowlist = cfg.skills.enable != [ ];
in
{
  options.codingAgents.skills = {
    sources = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          freeformType = (lib.types.attrsOf lib.types.unspecified);
        }
      );
      default = { };
      description = ''
        Skill catalog sources, forwarded to programs.agent-skills.sources.
        Each entry is either { input = "<flake-input-name>"; subdir = "..."; idPrefix = "..."; }
        or { path = ./relative-path; idPrefix = "..."; }.
      '';
    };
    enable = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Allowlist of skill IDs to bundle and deploy, of the form
        "<idPrefix>/<skill-name>". Skills not on the allowlist are not deployed.
      '';
    };
  };

  config = {
    codingAgents.skills.sources = {
      own = {
        path = ./own;
        idPrefix = "own";
      };
    };

    programs.agent-skills = lib.mkIf (anyTargetEnabled && hasAllowlist) {
      enable = true;
      sources = cfg.skills.sources;
      skills.enable = cfg.skills.enable;
      targets.claude.enable = claudeEnabled;
      targets.opencode = {
        enable = opencodeEnabled;
        dest = "$HOME/.config/opencode/skills";
        structure = "symlink-tree";
      };
    };
  };
}
```

Notes:
- The `hasAllowlist` gate is the spec's "implementation must enforce non-empty allowlist" requirement. Without it, hosts that set `<tool>.skills = true` (directly or via the parent default) but haven't added any skill IDs would emit a noisy `agent-skills-nix` warning about enabled-with-no-content.
- `freeformType` on `sources` keeps the option open-ended so users can pass any attrs `agent-skills-nix` accepts (`input`, `subdir`, `path`, `idPrefix`, `filter`, etc.) without us re-declaring its full schema.
- The `own` source is set in `config.codingAgents.skills.sources` as a default (modules merge attrsets, so users adding more sources keep `own` automatically).
- Custom opencode target — `agent-skills-nix` ships defaults for claude, copilot, cursor, codex, gemini, windsurf, antigravity, and a generic `agents` target, but **not** opencode. We add it inline.

- [ ] **Step 4: Format, lock, and smoke-test**

```bash
nix develop --command nixfmt flake.nix home/coding-agents/skills/default.nix
```

Expected: exit 0.

Update the lock file to fetch the new input:

```bash
nix flake lock --update-input agent-skills 'path:.' 2>/dev/null || nix flake lock 'path:.'
```

Expected: `flake.lock` now contains an `agent-skills` node. The first form may not exist on older Nix versions; the fallback `nix flake lock 'path:.'` always works.

```bash
nix eval 'path:.#homeConfigurations."o__ni@Stepans-MacBook-Pro".config.codingAgents.skills.sources.own.path'
```

Expected output: a Nix store path ending in `.../home/coding-agents/skills/own`.

Now create a temp skill to verify deployment end-to-end. **Revert in Step 5 before committing.**

```bash
mkdir -p home/coding-agents/skills/own/_smoke
cat > home/coding-agents/skills/own/_smoke/SKILL.md <<'EOF'
---
name: _smoke
description: Temporary smoke-test skill for plan Task 3 — delete me.
---

Verify that home-manager deploys this skill to claude and opencode targets.
EOF
```

Add the skill ID to the allowlist via a temporary inline overlay in `home/coding-agents/skills/default.nix`. Inside the `config = { ... };` block, immediately after the `codingAgents.skills.sources = { ... };` assignment, add:

```nix

    # SMOKE-TEST: revert before commit (plan Task 3 Step 5).
    codingAgents.skills.enable = [ "own/_smoke" ];
```

(This sets the allowlist as part of the same merged `config` attrset.)

Re-format and build:

```bash
nix develop --command nixfmt home/coding-agents/skills/default.nix
ACT=$(nix build 'path:.#homeConfigurations."o__ni@Stepans-MacBook-Pro".activationPackage' --no-link --print-out-paths)
find "$ACT/home-files" -name 'SKILL.md' -path '*_smoke*'
```

Expected output: two paths —
- `<store>/home-files/.claude/skills/own/_smoke/SKILL.md`
- `<store>/home-files/.config/opencode/skills/own/_smoke/SKILL.md`

Verify content of one:

```bash
head -2 "$ACT/home-files/.claude/skills/own/_smoke/SKILL.md"
```

Expected: `---` followed by `name: _smoke`.

If neither path appears, the gating in `programs.agent-skills` is not firing — re-check `anyTargetEnabled && hasAllowlist`. If only the claude path appears, the custom opencode target is misconfigured — re-check Step 3.

- [ ] **Step 5: Revert the smoke-test changes**

```bash
rm -r home/coding-agents/skills/own/_smoke
```

Open `home/coding-agents/skills/default.nix` and remove the smoke block (the comment line plus `codingAgents.skills.enable = [ "own/_smoke" ];`) so the file matches Step 3 again.

Verify the revert:

```bash
git diff home/coding-agents/skills/default.nix | grep -E '_smoke|codingAgents\.skills\.enable' || echo "clean"
```

Expected: `clean`.

```bash
test -d home/coding-agents/skills/own/_smoke && echo "STILL PRESENT" || echo "removed"
```

Expected: `removed`.

Re-build to confirm:

```bash
ACT=$(nix build 'path:.#homeConfigurations."o__ni@Stepans-MacBook-Pro".activationPackage' --no-link --print-out-paths)
find "$ACT/home-files" -path '*_smoke*' || echo "no smoke artifacts"
```

Expected: `no smoke artifacts`.

- [ ] **Step 6: Commit**

Stage exactly the four intended files (the two `home/coding-agents/skills/own/_smoke/*` artifacts must be gone — re-verify with `git status` first):

```bash
git status
```

Expected: only `flake.nix`, `flake.lock`, and `home/coding-agents/skills/default.nix` are modified; no untracked `_smoke*` files.

```bash
git add flake.nix flake.lock home/coding-agents/skills/default.nix
git commit -m "$(cat <<'EOF'
feat(home/coding-agents): implement skills sub-module via agent-skills-nix

Adds agent-skills-nix as a flake input and wraps programs.agent-skills
under the codingAgents.skills.{sources,enable} option tree. The wrapper
seeds an `own` source pointing at home/coding-agents/skills/own/ and
declares a custom opencode target (the upstream module ships defaults
for claude/cursor/codex/gemini/windsurf but not opencode).

programs.agent-skills.enable is gated on a non-empty allowlist + at
least one enabled target, so freshly-migrated hosts with no skills
yet stay quiet.
EOF
)"
```

Expected: clean commit.

---

## Task 4: Final validation

Run the full flake check and one last build of both macOS host activation packages to make sure nothing slipped between tasks. No commit in this task.

- [ ] **Step 1: Full flake check**

```bash
make check
```

(equivalent to `nix flake check 'path:.' --all-systems`)

Expected: exit 0. Warnings about unrelated NixOS systems being unbuildable on darwin are fine; what must NOT appear is anything mentioning `codingAgents`, `agent-skills`, missing options, or eval errors.

- [ ] **Step 2: Build both macOS hosts**

```bash
nix build 'path:.#homeConfigurations."o__ni@Stepans-MacBook-Pro".activationPackage' --no-link --print-out-paths
nix build 'path:.#homeConfigurations."o__ni@DodoBook.local".activationPackage' --no-link --print-out-paths
```

Expected: both print `/nix/store/...-home-manager-generation` paths. Both should also still deploy `~/.claude/CLAUDE.md` and `~/.config/opencode/AGENTS.md`. Skills and agents directories are not present yet (no own content, no allowlist, no agent definitions) — that's correct.

```bash
ACT=$(nix build 'path:.#homeConfigurations."o__ni@Stepans-MacBook-Pro".activationPackage' --no-link --print-out-paths)
find "$ACT/home-files" -name 'CLAUDE.md' -o -name 'AGENTS.md' -o -path '*/skills/*' -o -path '*/agents/*'
```

Expected: two paths — `CLAUDE.md` and `AGENTS.md`. No `skills/` or `agents/` paths (the framework is empty by design).

- [ ] **Step 3: Confirm branch state**

```bash
git log --oneline main..HEAD
```

Expected: three commits (Tasks 1, 2, 3) plus the spec commit from the brainstorming session — four commits total ahead of `main`.

```bash
git status
```

Expected: clean working tree, no untracked files.

The plan is complete. From here, the user can:
- Add their first own skill: create `home/coding-agents/skills/own/<name>/SKILL.md`, add `"own/<name>"` to `codingAgents.skills.enable` in the host config (or in `skills/default.nix`).
- Add their first own agent: create `home/coding-agents/agents/own/<name>.md`, register it in `home/coding-agents/agents/default.nix` via `config.codingAgents.agents.definitions.<name> = { source = ./own/<name>.md; targets = [...]; }`.
- Add an external skill source (e.g. `obra/superpowers`): add `inputs.superpowers = { url = "github:obra/superpowers"; flake = false; };` to `flake.nix`, then add `superpowers = { input = "superpowers"; subdir = "skills"; idPrefix = "superpowers"; };` to `codingAgents.skills.sources` in `home/coding-agents/skills/default.nix`, then add desired skill IDs to `codingAgents.skills.enable`.

---

## Self-Review Notes

- **Spec coverage:** Each spec section maps to a task —
  - File layout (spec § Architecture/File layout) → Tasks 1, 2, 3
  - Public option surface (spec § Architecture/Public option surface) → Task 1 (umbrella) + Task 2 (`agents.definitions`) + Task 3 (`skills.sources`/`skills.enable`)
  - Sub-module responsibilities (spec § Architecture/Sub-module responsibilities) → Tasks 1 (instructions), 2 (agents), 3 (skills)
  - Flake plumbing (spec § Architecture/Flake plumbing) → Task 3 Steps 1–2
  - Data flow (spec § Data flow) → empirically validated by smoke tests in Tasks 2 and 3
  - Per-host examples (spec § Per-host examples) → covered by host configs already present in `flake.nix` (Task 1 Step 8); no per-host change needed in this plan because the new sub-flags inherit from the existing `<tool>.enable = true;`
  - Edge cases (spec § Edge cases) → empty allowlist gating in Task 3 Step 3; `mkIf` defaults handle the disabled-host case structurally
  - Migration (spec § Migration) → entire Task 1 is the migration

- **Placeholder scan:** No `TBD`/`TODO`/handwaving. Every Nix file has its full content inline. Every command has expected output.

- **Type consistency:**
  - Option name `codingAgents.skills.enable` is `listOf str` — used consistently in Task 3 Step 3 (declaration) and Task 3 Step 4 (smoke test sets `[ "own/_smoke" ]`).
  - Option name `codingAgents.agents.definitions.<name>.{source,targets}` — same shape in Task 2 Step 1 (declaration), Step 3 (smoke), and Task 4 Step 3 (post-plan recipe).
  - Tool names `claude`/`opencode` — consistent across umbrella (Task 1), `targetPaths` (Task 2), and `targets.claude.enable`/`targets.opencode` (Task 3).
  - Frontmatter field `name:` (singular) — used in both smoke skill and smoke agent samples.

- **Git workflow:** Task 1 Step 9, Task 2 Step 5, Task 3 Step 6 all use HEREDOC commit messages with NO `Co-Authored-By` trailer (per global AGENTS.md). Files are staged explicitly by path.

- **Branch:** Already on `feat/coding-agents-skills-and-agents` per the brainstorming session; this plan does not switch branches.
