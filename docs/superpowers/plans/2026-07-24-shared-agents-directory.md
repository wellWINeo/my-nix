# Shared Agent Assets Directory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the common opencode and Codex instructions and skills to the shared `~/.agents` directory while preserving Claude and harness-specific agent definitions.

**Architecture:** Keep Claude on its existing native targets. Replace the separate opencode and Codex instruction files with one `~/.agents/AGENTS.md` `home.file` entry, and replace their separate `agent-skills-nix` targets with the upstream shared `agents` target at `~/.agents/skills`. Add a temporary guarded activation cleanup for legacy skill trees because those trees are not Home Manager `home.file` entries.

**Tech Stack:** Nix flakes, Home Manager release 26.05, `agent-skills-nix`, `nixfmt`.

## Global Constraints

- Use the existing `codingAgents` option tree; do not add a new command subsystem.
- Use `programs.agent-skills.targets.agents` for the shared skill destination.
- Keep Claude at `~/.claude/CLAUDE.md` and `~/.claude/skills/`.
- Do not move or convert schema-specific agent definition files.
- Home Manager must remove old instruction symlinks through normal generation cleanup.
- Legacy skill cleanup may remove only trees whose top-level entries all resolve into `/nix/store`.
- Preserve legacy trees containing `.system`, regular files, or non-store symlinks.
- Include a contextual TODO comment marking the temporary cleanup hook for later removal.
- Do not add dependencies, change flake inputs, or commit changes unless explicitly requested.

---

## File Structure

| File | Action | Responsibility |
| --- | --- | --- |
| `home/coding-agents/instructions/default.nix` | modify | Keep Claude's native file and add the shared `.agents/AGENTS.md` destination. |
| `home/coding-agents/skills/default.nix` | modify | Enable the shared `agents` skill target, disable the opencode/Codex targets, and clean safe legacy trees. |
| `README.md` | modify | Document the shared coding-agent asset layout and the schema-specific agent-file boundary. |
| `docs/superpowers/specs/2026-07-24-shared-agents-directory-design.md` | create | Record the approved architecture and migration behavior. |
| `docs/superpowers/plans/2026-07-24-shared-agents-directory.md` | create | This implementation plan. |

No changes are planned for `flake.nix`, `flake.lock`, `home/coding-agents/default.nix`, or `home/coding-agents/agents/default.nix`.

---

## Task 1: Update shared instruction destinations

**Files:**
- Modify: `home/coding-agents/instructions/default.nix`

**Interfaces:**
- Consumes: `codingAgents.claude.{enable,instructions}`, `codingAgents.opencode.{enable,instructions}`, and `codingAgents.codex.{enable,instructions}`.
- Produces: `home.file.".claude/CLAUDE.md"` for Claude and `home.file.".agents/AGENTS.md"` for opencode/Codex.

- [ ] **Step 1: Replace the opencode and Codex predicates with one shared predicate**

Keep the existing Claude predicate and define:

```nix
  enableShared =
    (cfg.opencode.enable && cfg.opencode.instructions)
    || (cfg.codex.enable && cfg.codex.instructions);
```

The complete module should be:

```nix
{ lib, config, ... }:

let
  cfg = config.codingAgents;
  enableClaude = cfg.claude.enable && cfg.claude.instructions;
  enableShared =
    (cfg.opencode.enable && cfg.opencode.instructions)
    || (cfg.codex.enable && cfg.codex.instructions);
in
{
  config = {
    home.file.".claude/CLAUDE.md" = lib.mkIf enableClaude {
      source = ./AGENTS.md;
    };
    home.file.".agents/AGENTS.md" = lib.mkIf enableShared {
      source = ./AGENTS.md;
    };
  };
}
```

- [ ] **Step 2: Format the module**

Run:

```bash
nix develop --command nixfmt home/coding-agents/instructions/default.nix
```

Expected: exit 0.

- [ ] **Step 3: Evaluate instruction entries for both hosts**

Run:

```bash
nix eval --impure --json --expr '
  let
    flake = builtins.getFlake (toString ./.);
    cfg = flake.homeConfigurations."o__ni@Stepans-MacBook-Pro".config;
  in {
    shared = cfg.home.file ? ".agents/AGENTS.md";
    oldOpencode = cfg.home.file ? ".config/opencode/AGENTS.md";
    oldCodex = cfg.home.file ? ".codex/AGENTS.md";
  }
'
```

Expected:

```json
{"shared":true,"oldOpencode":false,"oldCodex":false}
```

Repeat the same expression with `o__ni@DodoBook.local` substituted for the
Stepans host. It must produce the same result.

- [ ] **Step 4: Build and inspect the instruction files**

Run:

```bash
ACT=$(nix build 'path:.#homeConfigurations."o__ni@Stepans-MacBook-Pro".activationPackage' --no-link --print-out-paths)
test -e "$ACT/home-files/.claude/CLAUDE.md"
test -e "$ACT/home-files/.agents/AGENTS.md"
test ! -e "$ACT/home-files/.config/opencode/AGENTS.md"
test ! -e "$ACT/home-files/.codex/AGENTS.md"
```

Expected: all commands exit 0. Home Manager will remove the old instruction
symlinks during activation because they were tracked `home.file` entries in
the previous generation.

---

## Task 2: Use the shared skill target and remove legacy skill trees safely

**Files:**
- Modify: `home/coding-agents/skills/default.nix`

**Interfaces:**
- Consumes: existing skill sources and `codingAgents.<tool>.{enable,skills}` flags.
- Produces: `programs.agent-skills.targets.agents.enable` and a temporary
  `home.activation` migration action.

- [ ] **Step 1: Replace the separate target predicates**

Replace the current `opencodeEnabled` and `codexEnabled` declarations with:

```nix
  sharedEnabled =
    (cfg.opencode.enable && cfg.opencode.skills)
    || (cfg.codex.enable && cfg.codex.skills);
  anyTargetEnabled = claudeEnabled || sharedEnabled;
```

Keep `claudeEnabled` and the existing selection logic unchanged.

- [ ] **Step 2: Replace the target configuration**

Replace the current opencode and Codex target entries:

```nix
      targets.opencode = {
        enable = opencodeEnabled;
        dest = "$HOME/.config/opencode/skills";
        structure = "symlink-tree";
      };
      targets.codex.enable = codexEnabled;
```

with the shared upstream target:

```nix
      targets.agents.enable = sharedEnabled;
```

Do not set `dest` unless evaluation proves the pinned `agent-skills-nix`
version does not provide the documented default `$HOME/.agents/skills`.

- [ ] **Step 3: Add the guarded legacy cleanup action**

Inside the existing `config = { ... };` block, add this temporary action after
the `programs.agent-skills` assignment:

```nix
    home.activation.removeLegacyAgentSkillTrees = lib.mkIf (cfg.opencode.enable || cfg.codex.enable) (
      lib.hm.dag.entryAfter (
        [ "writeBoundary" ] ++ lib.optional (config.home.activation ? "agent-skills") "agent-skills"
      ) ''
        is_nix_store_skill_tree() {
          local tree="$1"
          local entry target

          [[ -d "$tree" && ! -L "$tree" ]] || return 1

          if ! (
            set -o pipefail
            find "$tree" -mindepth 1 -maxdepth 1 -print0 |
              while IFS= read -r -d "" entry; do
                [[ "$(basename "$entry")" == ".system" ]] && return 1
                [[ -L "$entry" ]] || return 1
                target="$(readlink -f "$entry" || true)"
                [[ "$target" == /nix/store/* ]] || return 1
              done
          ); then
            return 1
          fi

          return 0
        }

        # TODO: remove this migration action after all supported hosts have
        # activated a generation using the shared ~/.agents skill target.
        for legacy in "$HOME/.config/opencode/skills" "''${CODEX_HOME:-$HOME/.codex}/skills"; do
          if is_nix_store_skill_tree "$legacy"; then
            run rm -rf "$legacy"
          fi
        done
      ''
    );
```

The function deliberately rejects `.system`, regular files, non-store
symlinks, and failed enumeration. The `run` helper keeps the action compatible
with Home Manager dry runs.

- [ ] **Step 4: Format the skills module**

Run:

```bash
nix develop --command nixfmt home/coding-agents/skills/default.nix
```

Expected: exit 0.

- [ ] **Step 5: Evaluate shared skill target behavior**

Run:

```bash
nix eval --impure --json --expr '
  let
    flake = builtins.getFlake (toString ./.);
    cfg = flake.homeConfigurations."o__ni@Stepans-MacBook-Pro".config;
  in {
    sharedEnabled = cfg.programs.agent-skills.targets.agents.enable;
    sharedDestination = cfg.programs.agent-skills.targets.agents.dest;
    opencodeEnabled = cfg.programs.agent-skills.targets.opencode.enable;
    codexEnabled = cfg.programs.agent-skills.targets.codex.enable;
  }
'
```

Expected:

```json
{"sharedEnabled":true,"sharedDestination":"$HOME/.agents/skills","opencodeEnabled":false,"codexEnabled":false}
```

The individual `opencode` and `codex` target options may still exist as
upstream defaults; they must be disabled, not necessarily absent.

- [ ] **Step 6: Inspect the generated activation script**

Run:

```bash
ACT=$(nix build 'path:.#homeConfigurations."o__ni@Stepans-MacBook-Pro".activationPackage' --no-link --print-out-paths)
rg -n 'targets\.agents|\.agents/skills|removeLegacyAgentSkillTrees|\.config/opencode/skills|CODEX_HOME' "$ACT/activate"
```

Expected: the activation script contains the shared destination and the
guarded legacy cleanup paths. It must not contain an active opencode or Codex
`agent-skills` target configuration.

- [ ] **Step 7: Confirm cleanup guard behavior with a temporary shell test**

Use a temporary directory outside the repository to execute the same guard
logic against a store-only tree, a tree containing `.system` and user data,
and a tree containing a non-store symlink:

```bash
set -eu

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

is_nix_store_skill_tree() {
  local tree="$1"
  local entry target

  [[ -d "$tree" && ! -L "$tree" ]] || return 1

  if ! (
    set -o pipefail
    find "$tree" -mindepth 1 -maxdepth 1 -print0 |
      while IFS= read -r -d "" entry; do
        [[ "$(basename "$entry")" == ".system" ]] && return 1
        [[ -L "$entry" ]] || return 1
        target="$(readlink -f "$entry" || true)"
        [[ "$target" == /nix/store/* ]] || return 1
      done
  ); then
    return 1
  fi

  return 0
}

store_target=$(find /nix/store -mindepth 1 -maxdepth 1 -print -quit)
test -n "$store_target"

mkdir -p "$tmp/store-tree" "$tmp/system-tree/.system" "$tmp/user-tree" "$tmp/non-store-tree" "$tmp/failing-bin"
ln -s "$store_target" "$tmp/store-tree/skill"
ln -s "$tmp/store-tree" "$tmp/root-symlink"
printf '%s\n' user-data > "$tmp/user-tree/notes.txt"
ln -s "$tmp/non-store-tree" "$tmp/non-store-tree/skill"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$tmp/failing-bin/find"
chmod +x "$tmp/failing-bin/find"

is_nix_store_skill_tree "$tmp/store-tree"
! is_nix_store_skill_tree "$tmp/root-symlink"
! is_nix_store_skill_tree "$tmp/system-tree"
! is_nix_store_skill_tree "$tmp/user-tree"
! is_nix_store_skill_tree "$tmp/non-store-tree"

(
  PATH="$tmp/failing-bin:$PATH"
  export PATH
  ! is_nix_store_skill_tree "$tmp/store-tree"
)
```

Expected: all assertions pass. The store-only tree is eligible for removal;
the user-data, `.system`, and non-store-symlink trees are rejected, and a
failed enumeration is also rejected. The positive fixture points to an actual
child of `/nix/store`, not `/nix/store` itself. Do not use a real home directory
for this smoke test.

---

## Task 3: Document the resulting asset boundaries

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: the final target layout from Tasks 1 and 2.
- Produces: concise repository documentation for future changes.

- [ ] **Step 1: Update the home-manager directory description**

Change the `home/coding-agents/` description in the README from the
Claude/opencode-only wording to identify Claude, opencode, and Codex support,
with shared `.agents` assets.

- [ ] **Step 2: Add the supported global asset layout**

After the home-manager directory structure, add this short section:

```markdown
### Coding-agent assets

- Shared opencode/Codex instructions: `~/.agents/AGENTS.md`
- Shared opencode/Codex skills: `~/.agents/skills/`
- Claude instructions and skills: `~/.claude/`
- Harness-specific agent definitions remain under their native directories.

This repository does not currently manage custom command files. OpenCode and
Codex use different custom-agent formats, so agent definitions are not moved
to a shared `.agents/agents/` directory.
```

- [ ] **Step 3: Review documentation for stale paths**

Run:

```bash
rg -n '\.config/opencode/(AGENTS\.md|skills)|\.codex/AGENTS\.md|CODEX_HOME' README.md
```

Expected: no output.

---

## Task 4: Final validation

**Files:**
- Test: both macOS Home Manager configurations and the full flake.

- [ ] **Step 1: Ensure validation secrets exist**

Run:

```bash
test -f secrets/secrets.json || make setup-dummy-secrets
```

Expected: `secrets/secrets.json` exists. Do not replace an existing unlocked
secret file.

- [ ] **Step 2: Format all changed Nix files**

Run:

```bash
nix develop --command nixfmt \
  home/coding-agents/instructions/default.nix \
  home/coding-agents/skills/default.nix
```

Expected: exit 0.

- [ ] **Step 3: Build both activation packages**

Run:

```bash
nix build 'path:.#homeConfigurations."o__ni@Stepans-MacBook-Pro".activationPackage' --no-link --print-out-paths
nix build 'path:.#homeConfigurations."o__ni@DodoBook.local".activationPackage' --no-link --print-out-paths
```

Expected: both commands print a `/nix/store/...-home-manager-generation`
path and exit 0.

- [ ] **Step 4: Inspect both generated home-file trees**

Run:

```bash
for host in 'o__ni@Stepans-MacBook-Pro' 'o__ni@DodoBook.local'; do
  ACT=$(nix build "path:.#homeConfigurations.\"$host\".activationPackage" --no-link --print-out-paths)
  test -e "$ACT/home-files/.agents/AGENTS.md"
  test -e "$ACT/home-files/.claude/CLAUDE.md"
  test ! -e "$ACT/home-files/.config/opencode/AGENTS.md"
  test ! -e "$ACT/home-files/.codex/AGENTS.md"
done
```

Expected: all assertions pass for both hosts.

- [ ] **Step 5: Run the full flake check**

Run:

```bash
make check
```

Expected: exit 0. Warnings about unrelated systems are acceptable; there
must be no missing-option, target, activation, or Home Manager evaluation
errors.

- [ ] **Step 6: Review the final diff**

Run:

```bash
git status --short
```

Expected: only the two Nix modules, `README.md`, and the two new design/plan
documents are changed. Do not commit until explicitly requested.

---

## Self-Review

- **Spec coverage:** shared instructions map to Task 1; shared skills and
  target replacement map to Task 2; conservative legacy cleanup is specified
  in Task 2; documentation maps to Task 3; build and flake validation map to
  Task 4.
- **Placeholder scan:** the only TODO marker is the explicitly requested,
  contextual migration-hook removal marker. No step relies on unspecified
  implementation work.
- **Type consistency:** `sharedEnabled` is used for both the instruction and
  skill shared predicates; `targets.agents` is the only shared skill target;
  `opencode` and `codex` remain valid option names but are disabled.
- **Scope check:** no command module, new dependency, flake input, or agent
  format conversion is introduced.
- **Safety check:** Home Manager handles old `home.file` symlinks; the custom
  cleanup only removes a directory after confirming successful enumeration and
  that all top-level entries are Nix-store symlinks, and rejects `.system` or
  user content.
