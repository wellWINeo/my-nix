# Shared Agent Assets Directory

**Status:** approved
**Date:** 2026-07-24

## Goal

Use the shared user-level `~/.agents` directory for the common coding-agent
assets consumed by opencode and Codex, instead of maintaining duplicate
opencode- and Codex-specific instruction and skill destinations.

## Scope

The migration covers the assets this repository currently manages:

- Shared global instructions at `~/.agents/AGENTS.md`.
- Shared skills at `~/.agents/skills/`.
- Claude instructions and skills remain at their native `~/.claude/` paths.

The repository has no command asset source or deployment module, so this
change does not add command support. Existing agent definition files remain at
their harness-specific paths because OpenCode uses Markdown agents while Codex
uses TOML custom-agent files; no common `.agents/agents` format is documented.

## Non-goals

- Adding a `codingAgents.commands` option or command source tree.
- Converting OpenCode Markdown agent definitions into Codex TOML.
- Moving Claude assets into `~/.agents`.
- Keeping duplicate opencode or Codex skill trees after migration.
- Unconditionally deleting user-managed files from legacy directories.

## Architecture

### Instructions

`home/coding-agents/instructions/default.nix` will keep the Claude entry at
`~/.claude/CLAUDE.md`. The opencode and Codex entries will be replaced with one
shared `~/.agents/AGENTS.md` entry, enabled when either harness has both its
master and instruction flags enabled.

The source remains `home/coding-agents/instructions/AGENTS.md`.

### Skills

`home/coding-agents/skills/default.nix` will continue to expose independent
Claude enablement, but opencode and Codex will share one predicate:

```nix
sharedEnabled =
  (cfg.opencode.enable && cfg.opencode.skills)
  || (cfg.codex.enable && cfg.codex.skills);
```

The module will enable `programs.agent-skills.targets.agents`, whose upstream
default destination is `$HOME/.agents/skills`, and will stop enabling the
`opencode` and `codex` targets. The existing skill catalog, selection, and
bundle behavior remain unchanged.

### Legacy skill cleanup

Home Manager's normal generation cleanup removes the old instruction
symlinks because they are `home.file` entries. It does not remove the old
skill trees because `agent-skills-nix` creates them through an activation
script rather than `home.file`.

The skills module will therefore add a temporary migration activation hook.
The hook will inspect `~/.config/opencode/skills` and
`${CODEX_HOME:-$HOME/.codex}/skills`, and remove a legacy tree only when every
top-level entry is a symlink resolving into `/nix/store`. A tree containing
`.system`, regular files, or other non-store content will be left untouched.
Enumeration failures also reject the tree. The hook will use Home Manager's
`run` helper so dry-run behavior remains correct and will include a contextual
TODO comment to remove the hook after the legacy generations have retired.
When the `agent-skills` activation node exists, the cleanup node will run after
it; otherwise it will depend only on `writeBoundary`.

## Resulting Layout

```text
~/.agents/AGENTS.md              # shared opencode + Codex instructions
~/.agents/skills/                # shared opencode + Codex skills
~/.claude/CLAUDE.md              # Claude instructions
~/.claude/skills/                # Claude skills
~/.claude/agents/                # Claude-specific agent definitions
~/.config/opencode/agents/       # OpenCode-specific agent definitions
```

The migration no longer declares `~/.config/opencode/AGENTS.md`,
`~/.codex/AGENTS.md`, `~/.config/opencode/skills/`, or
`${CODEX_HOME:-$HOME/.codex}/skills/` as active destinations.

## Verification

Validation will use the repository's existing Nix workflow:

1. Format the two modified Nix modules with `nixfmt`.
2. Evaluate both macOS configurations and assert that the shared target is
   enabled while the opencode and Codex skill targets are disabled.
3. Build both Home Manager activation packages.
4. Inspect the generated `home-files` tree for `.agents/AGENTS.md` and the
   absence of the old instruction paths.
5. Run `make check`.

No automated test framework is introduced.

## Trade-offs

- The shared skill target is the upstream `agent-skills-nix` `agents` target,
  avoiding a custom destination that could drift from the standard.
- The shared instruction destination follows the requested harness behavior,
  while Claude keeps its established native filename.
- Schema-specific agent files remain duplicated by design rather than adding a
  format conversion layer with uncertain compatibility.
- The legacy cleanup hook is temporary and conservative. It favors preserving
  user data over removing every stale directory automatically.
