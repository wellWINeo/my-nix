# Coding-Agent Skills and Agents via home-manager

**Status:** approved
**Date:** 2026-04-26

## Goal

Extend the existing `home/coding-agents/` home-manager module so it manages
three classes of coding-agent assets from a single source of truth:

1. **Instructions** — global `AGENTS.md`/`CLAUDE.md` (already in place).
2. **Skills** — directories containing `SKILL.md`, sourced from external flake
   inputs (e.g. `obra/superpowers`) *and* from local files authored in this
   repo.
3. **Agents** — single `.md` files (opencode primary agents and subagents,
   Claude Code subagents), authored locally and deployed to the right
   per-tool location.

Asset deployment is gated per-host, per-tool, per-asset-class so a work
machine can opt out of e.g. Claude Code agents without losing opencode
agents.

## Non-goals

- Per-project skills/agents (only global, user-level deployment).
- GitHub Copilot or other tools as deployment targets (Claude Code +
  opencode only for now).
- Per-host model identifier substitution in agent frontmatter. Authored
  agent files omit `model` and let the tool's own model-inheritance
  behaviour handle portability across GLM/openrouter/Copilot. A mapping
  layer is deferred until a real agent needs to pin a model.
- Validation/lint on skill or agent frontmatter — relies on the agent tool
  itself to surface errors.
- A NixOS-side (system-wide) variant. This is home-manager only.
- Tool-specific divergent text in `AGENTS.md`. Both tools still symlink the
  same source.
- Hand-rolling skill discovery: we use the upstream `agent-skills-nix`
  flake for skills.

## Architecture

### High level

A single umbrella module `home/coding-agents/default.nix` declares the
public option tree and imports three sub-modules:

- `instructions/` — symlinks `AGENTS.md` into each tool's expected path.
  (Migrated from the current `home/coding-agents/{default.nix,AGENTS.md}`.)
- `skills/` — thin wrapper around `programs.agent-skills` from
  [Kyure-A/agent-skills-nix](https://github.com/Kyure-A/agent-skills-nix);
  declares sources (external flake inputs + local `./own/`), an allowlist
  of skill IDs to deploy, and per-tool target enable flags.
- `agents/` — bespoke ~30-line module that registers each `./own/<name>.md`
  with a `targets` list (`["claude"]`, `["opencode"]`, or both) and emits
  the appropriate `home.file` entries per host.

External skill sources enter as `flake = false;` flake inputs, pinned via
`flake.lock`. Updates use `nix flake update <input>`.

### File layout

```
home/coding-agents/
  default.nix                     # umbrella: option tree + imports sub-modules
  instructions/
    default.nix                   # CLAUDE.md + opencode AGENTS.md wiring (migrated)
    AGENTS.md                     # source of truth (migrated as-is)
  skills/
    default.nix                   # wraps programs.agent-skills
    own/
      <skill-name>/SKILL.md       # local skills authored in this repo
  agents/
    default.nix                   # discovers and deploys ./own/*.md
    own/
      <name>.md                   # local agent files
```

### Public option surface

```nix
codingAgents = {
  claude = {
    enable       = bool;          # master switch for Claude Code asset deployment
    instructions = bool;          # default: claude.enable
    skills       = bool;          # default: claude.enable
    agents       = bool;          # default: claude.enable
  };
  opencode = {
    enable       = bool;          # master switch for opencode asset deployment
    instructions = bool;          # default: opencode.enable
    skills       = bool;          # default: opencode.enable
    agents       = bool;          # default: opencode.enable
  };

  # Catalog declared once at module level (host-independent):
  skills = {
    sources = attrsOf (submodule {
      options = {
        input    = mkOption { type = nullOr str;  default = null; };  # name in inputs
        subdir   = mkOption { type = nullOr str;  default = null; };  # path within input
        path     = mkOption { type = nullOr path; default = null; };  # local path
        idPrefix = mkOption { type = nullOr str;  default = null; };
      };
    });
    enable = listOf str;          # allowlist of skill IDs, of the form "<idPrefix>/<skill-name>"
  };

  agents.definitions = attrsOf (submodule {
    options = {
      source  = mkOption { type = path; };
      targets = mkOption {
        type    = listOf (enum [ "claude" "opencode" ]);
        default = [ "claude" "opencode" ];
      };
    };
  });
};
```

The defaulting rule `<sub-flag> default = <tool>.enable` means simple
hosts only need `codingAgents.<tool>.enable = true;` to get everything;
hosts can opt sub-classes out individually.

### Sub-module responsibilities

**`instructions/default.nix`** (~10 lines)

Replaces today's `home/coding-agents/default.nix`. Reads
`codingAgents.{claude,opencode}.{enable,instructions}` and emits two
optional `home.file` entries pointing at `./AGENTS.md`.

**`skills/default.nix`** (~30 lines)

Forwards `codingAgents.skills.{sources,enable}` to
`programs.agent-skills.{sources,skills.enable}`. Declares two targets:

- `targets.claude` — built-in to `agent-skills-nix`, dest
  `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills`. Enabled iff
  `codingAgents.claude.enable && codingAgents.claude.skills`.
- `targets.opencode` — custom (not built-in upstream), dest
  `$HOME/.config/opencode/skills`, structure `symlink-tree`. Enabled iff
  `codingAgents.opencode.enable && codingAgents.opencode.skills`.

**`agents/default.nix`** (~30 lines)

Walks `codingAgents.agents.definitions` and, for each `(definition, target)`
pair where the host enables both `codingAgents.<target>.enable` and
`codingAgents.<target>.agents`, emits one `home.file` entry:

| Target   | Path                                          |
|----------|-----------------------------------------------|
| claude   | `~/.claude/agents/<name>.md`                  |
| opencode | `~/.config/opencode/agents/<name>.md`         |

The module also registers the repo's authored agents in its own `config`
block, e.g.

```nix
config.codingAgents.agents.definitions = {
  code-reviewer    = { source = ./own/code-reviewer.md;    targets = [ "claude" "opencode" ]; };
  opencode-primary = { source = ./own/opencode-primary.md; targets = [ "opencode" ]; };
};
```

Authored agent `.md` files **omit `model:`** so the tool's own model
inheritance handles cross-host portability (GLM/openrouter on personal,
Copilot on work).

### Flake plumbing

`flake.nix` changes:

1. **New inputs.** `agent-skills` (the flake) plus one per external skill
   source:
   ```nix
   agent-skills.url = "github:Kyure-A/agent-skills-nix";
   superpowers = { url = "github:obra/superpowers"; flake = false; };
   # add additional external skill sources the same way
   ```
2. **Per-host wiring.** Both `homeConfigurations.*` entries get:
   ```nix
   extraSpecialArgs = { inherit inputs; };
   modules = [
     inputs.agent-skills.homeManagerModules.default
     ./home
     { /* existing host-specific opts */ }
   ];
   ```
   `extraSpecialArgs` is required for `homeManagerConfiguration` (the
   `specialArgs` form is NixOS-only).

`home/coding-agents/skills/default.nix` consumes `inputs` to register
sources:

```nix
{ inputs, ... }: {
  config.codingAgents.skills.sources = {
    superpowers = { input = "superpowers"; subdir = "skills"; idPrefix = "superpowers"; };
    own         = { path  = ./own; idPrefix = "own"; };
  };
  # And in the host (or this module, since it's shared across hosts):
  config.codingAgents.skills.enable = [
    "superpowers/brainstorming"
    "own/my-debugging-helper"
  ];
}
```

`agent-skills-nix` accepts `{ input = "<name>"; }` (looked up in `inputs`)
or `{ path = ./local; }`. We always set `idPrefix` per source to avoid
ID collisions across sources.

## Data flow

End-to-end on `home-manager switch` for a host with everything enabled:

1. **Instructions.** `instructions/AGENTS.md` is copied into the nix store
   as part of `home-manager-files`; `~/.claude/CLAUDE.md` and
   `~/.config/opencode/AGENTS.md` symlink to that store path.
2. **Skills.**
   1. Flake inputs (`superpowers`, etc.) are fetched and pinned by
      `flake.lock`.
   2. The umbrella module passes `inputs` through to the skills sub-module.
   3. `agent-skills-nix` discovers all `SKILL.md` directories under each
      source, building a catalog of IDs (`<idPrefix>/<name>`).
   4. The allowlist (`codingAgents.skills.enable`) selects which IDs land
      in the bundle.
   5. The bundle is materialized as one nix store path containing
      `<id>/SKILL.md` entries.
   6. Per-target enable flags symlink the bundle into
      `~/.claude/skills/` and `~/.config/opencode/skills/`. opencode also
      reads `~/.claude/skills/` natively, so the opencode target is
      strictly belt-and-braces but kept for explicitness.
3. **Agents.** For each `(name, target)` pair where the host enables both
   `codingAgents.<target>.enable` and `codingAgents.<target>.agents`:
   - Source: `home/coding-agents/agents/own/<name>.md`
   - Destination symlink:
     - claude → `~/.claude/agents/<name>.md`
     - opencode → `~/.config/opencode/agents/<name>.md`

### Update flow

| Change                              | Command                                    |
|-------------------------------------|--------------------------------------------|
| Edit instructions/skill/agent       | `home-manager switch`                      |
| Pull new upstream skill source      | `nix flake update <input>` then switch     |
| Add a brand-new external source     | edit `flake.nix` + `skills/default.nix`    |

## Per-host examples

Personal MacBook (`Stepans-MacBook-Pro`) — everything on:

```nix
codingAgents.claude.enable   = true;
codingAgents.opencode.enable = true;
```

Work MacBook (`DodoBook.local`) — instructions everywhere, but skills and
agents only via opencode (the path Copilot reaches the model through):

```nix
codingAgents.claude.enable      = true;
codingAgents.claude.skills      = false;
codingAgents.claude.agents      = false;
codingAgents.opencode.enable    = true;
```

## Edge cases

- **Allowlist references a non-existent skill ID** — `agent-skills-nix`
  errors at evaluation time. Fails fast.
- **Two sources export the same skill ID** — every source declares
  `idPrefix`, so collisions are structurally avoided.
- **Frontmatter field one tool doesn't understand** (e.g. opencode's
  `mode: primary` in a file Claude Code reads) — both tools tolerate
  unknown fields today. If that changes, the per-agent `targets` list
  scopes the file out.
- **Host enables `<tool>.skills = true` with empty allowlist** — target
  directory is created empty; no error.
- **Host disables `<tool>.enable` entirely** — defaulting cascades, no
  files emitted by this module for that tool.
- **External skill source is private** — `flake = false;` requires git
  auth at evaluation time. Out of scope; document as a known limitation.

## Trade-offs accepted

- **`agent-skills-nix` adds an evaluation dependency.** Small flake, no
  IFD, accepted in exchange for not reimplementing skill discovery.
- **One source `.md` per agent (no per-tool divergence).** If Claude
  Code's subagent format diverges meaningfully from opencode's, the
  `targets` list + duplicating the file is the escape hatch.
- **Model identifier omitted from agent files.** Per-host model
  substitution is deferred until a concrete agent needs it.
- **Both tools share `instructions/AGENTS.md`.** If they need to diverge,
  the `instructions/` directory grows two source files and the symlinks
  change accordingly.
- **Each external source = one new flake input + one new
  `sources.<name>` entry** (~6 lines). Acceptable for the expected ≤3
  sources; if it grows past ~10, derive the source list from `inputs`
  attributes automatically.

## Migration

The existing `home/coding-agents/{default.nix, AGENTS.md}` files move
into `home/coding-agents/instructions/` and the new umbrella `default.nix`
takes their place. The public option paths change:

| Before                                | After                                            |
|---------------------------------------|--------------------------------------------------|
| `codingAgents.claude.enable`          | `codingAgents.claude.enable` (semantics broaden) |
| `codingAgents.opencode.enable`        | `codingAgents.opencode.enable` (semantics broaden) |
| (none)                                | `codingAgents.<tool>.{instructions,skills,agents}` |

Existing host configs (`codingAgents.claude.enable = true;`) continue to
work unchanged because the new sub-flags default to the parent's value.
The semantic broadening is intentional: today `enable = true` means
"deploy instructions", after this change it means "deploy everything for
this tool".

On a host enabling `<tool>.skills = true` (directly or via the default)
when `codingAgents.skills.enable = []` and no agent definitions are
registered, the result is benign — no skills bundle, no agent files —
provided the umbrella module gates `programs.agent-skills.enable` on a
non-empty allowlist. Implementation must enforce this to avoid spurious
warnings from `agent-skills-nix` about "enabled with no targets" on a
freshly-migrated host before any allowlist or agents are added.

## Out of scope (future work)

- Frontmatter validation/lint for skills and agents.
- Per-host model identifier mapping (Q4-B from brainstorm).
- NixOS-level (system-wide) variant.
- Deriving the `sources` allowlist automatically from `inputs.*`.
- GitHub Copilot, Cursor, Codex, etc. as targets.
- Per-project deployment (only global is in scope).
