# Global Coding-Agent Instructions via home-manager

**Status:** approved
**Date:** 2026-04-26

## Goal

Manage a single, user-level Markdown file containing root instructions for AI
coding agents, and have home-manager symlink it into the conventional locations
that Claude Code and opencode read at startup. One source of truth, one place to
edit, multiple targets.

## Non-goals

- Per-project `AGENTS.md` files. The repo root already contains one for *this*
  NixOS flake; that file is unchanged.
- Tool-specific divergent text. If Claude Code and opencode ever need different
  instructions, the module will need to grow — that is out of scope here.
- A separate `pkgs.runCommand`/`pkgs.writeText` derivation. The standard
  home-manager symlink-into-`home-manager-files` shape is sufficient.

## Architecture

A new home-manager module under `home/coding-agents/` defines two independent
enable flags. When a flag is enabled, the module places the shared source file
at the conventional location for that tool via `home.file`.

### Files

| Path                              | Purpose                                                           |
|-----------------------------------|-------------------------------------------------------------------|
| `home/coding-agents/default.nix`  | Module: options + `home.file` declarations                        |
| `home/coding-agents/AGENTS.md`    | Single source of truth, copied into the nix store by home-manager |

### Module shape

```nix
{ lib, config, ... }:

let
  cfg = config.codingAgents;
in
{
  options.codingAgents = {
    claude.enable = lib.mkEnableOption "global CLAUDE.md for Claude Code";
    opencode.enable = lib.mkEnableOption "global AGENTS.md for opencode";
  };

  config = {
    home.file.".claude/CLAUDE.md" = lib.mkIf cfg.claude.enable {
      source = ./AGENTS.md;
    };
    home.file.".config/opencode/AGENTS.md" = lib.mkIf cfg.opencode.enable {
      source = ./AGENTS.md;
    };
  };
}
```

### Wiring

- `home/default.nix` adds `./coding-agents` to `imports`, alongside
  `./software/alacritty`, `./software/neovim`, and `./tmux.nix`.
- Each `homeConfigurations.*` entry in `flake.nix` opts in by setting
  `codingAgents.claude.enable = true;` and/or `codingAgents.opencode.enable = true;`
  — mirrors the existing `software.alacritty.enable = true;` lines.
- Defaults are `false` (idiomatic `mkEnableOption`, matches existing
  `software.*` modules).

## Behavior

- After `home-manager switch` on an opted-in host:
  - `~/.claude/CLAUDE.md` → `/nix/store/<hash>-home-manager-files/.claude/CLAUDE.md`
  - `~/.config/opencode/AGENTS.md` → `/nix/store/<hash>-home-manager-files/.config/opencode/AGENTS.md`
  - Both store entries are bit-identical copies of `home/coding-agents/AGENTS.md`.
- Editing the source `.md` and re-activating updates both symlinks atomically.
- A host that enables neither flag gets no file linked; the module is a no-op.

## Content of `AGENTS.md`

The dummy version (committed as proof of work in step 5 of the workflow) is a
stub of section headers only. The real content is drafted by an opus subagent
in step 6 and must cover at least:

| Topic            | Required directive(s)                                                                                                                                                                                                                                                          |
|------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Attribution      | DO NOT add yourself to authors (no `Co-Authored-By` trailers, no signed-off-by lines for the agent).                                                                                                                                                                          |
| Pre-action       | MUST: before any action, look for common patterns in the repository and related documentation.                                                                                                                                                                                |
| Git workflow     | NEVER work directly on `master` without explicit user approval. If on `master`: propose a feature-branch name and ask to use a worktree. If on a feature branch (not in a worktree): ask whether to use a worktree or work on the current branch. If already in a worktree on a feature branch: proceed without asking. |

## Trade-offs accepted

- **Same source for both targets.** Acceptable since the directives are
  tool-agnostic. If divergence is needed later, split into per-target source
  files or templating.
- **Store path is `home-manager-files`, not `agents-config`.** No functional
  difference — the symlink still points into the nix store, so reproducibility
  and rebuild semantics are unchanged.

## Out of scope (future work)

- Validation/lint that the file contains the required directives.
- A NixOS-side variant for system-wide agent instructions (this is home-manager
  only by design).
- Hooking into `update-config` skill to sync hooks/permissions changes.
