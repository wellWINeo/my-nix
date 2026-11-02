# Kaiten CLI and shared skills on DodoBook

**Date:** 2026-11-02

**Status:** Design agreed in conversation; independent review completed with no findings. Implementation awaits approval.

**Implementation plan:** [Kaiten CLI on DodoBook](../plans/2026-11-02-kaiten-cli-dodobook.md)

## Intent and agreed decisions

Package [ViktorOgnev/kaiten-cli](https://github.com/ViktorOgnev/kaiten-cli) in this flake and install it through Home Manager only on `o__ni@DodoBook.local`. Install its upstream skills for Pi and Codex in the shared `~/.agents/skills` directory on that host.

The source strategy is a **shared, pinned, non-flake input**. This is the user's latest decision and supersedes the intermediate `fetchFromGitHub` proposal. The package and skills must consume the same input; neither receives a separate fetch or version pin.

The user authorized a regular feature branch, `feat/kaiten-cli-dodobook`, these two planning documents, and an independent subagent review. Implementation, activation, commits, and pushes are not authorized by this planning request.

## Goals and non-goals

- Expose a reproducible `kaiten-cli` flake package and the upstream `kaiten` command.
- Keep the package and its three skills on the same upstream revision.
- Install both only on DodoBook, without changing the other Mac's effective package or skill selection.
- Add the Kaiten skills to the shared target, not Claude's native skill directory.
- Use the existing overlay, Home Manager software modules, and `agent-skills-nix` integration.

Do not replace `kaiten-mcp`, install Pi/Codex themselves, add a gateway service, change agent settings or global instructions, manage credentials, enable live API tests, or set up shell completion. The upstream gateway executable may remain part of the Python package; it must not be started or configured.

## Existing constraints

The actual flake uses NixOS 26.05 and unstable nixpkgs for both macOS Home Manager configurations; some repository introductory documentation still names older channels. Follow `flake.nix` and `flake.lock`, not those historical descriptions.

Global overlays currently live in `overlays/default.nix`. Its list is imported three times in `flake.nix`: once for package sets and separately for mokosh and veles. Passing the new source into the overlay must preserve these existing consumers and their host-specific overlays.

`home/coding-agents/skills/default.nix` forwards catalog sources and the common selection to upstream. Both Macs already enable the shared `agents` target through OpenCode, as well as the independent `claude` target. Simply adding Kaiten to the common enable-all list would install its skills for Claude too.

The locked `agent-skills-nix` revision, `2948865044b2af55c8c4e4eb2abda7de79d60f0e`, supports `programs.agent-skills.skills.explicit.<name>.agents` and per-target `targetBundlePaths`. The local wrapper does not expose an `explicit` option; use the upstream option directly rather than adding another abstraction.

## Architecture

### One upstream input

Add `inputs.kaiten-cli` with `flake = false` and URL `github:ViktorOgnev/kaiten-cli/v0.3.3`. Resolve it through `nix flake lock`, retaining all existing dependency pins. The release tag was observed resolving to commit `18abe81aa52ad6a1cec0334452194691b06ad4f4`; stop and investigate if resolution differs.

Initial release `0.3.3` is the planning recommendation, carried forward from the discussed design. Future upgrades intentionally change this source and the package version together. The source lock also pins the skills, avoiding commands that do not exist in the installed release.

### Package and overlay

Create `pkgs/kaiten-cli/default.nix` with arguments `lib`, `python3Packages`, `src`, and the native tools required by upstream's offline tests. Build a Python application using `pyproject = true`, Hatchling, and version `0.3.3`. Runtime dependencies are `click >= 8.1`, `httpx >= 0.27.0`, and `platformdirs >= 4.2.0`; use the selected nixpkgs Python package set, not pip downloads or a vendored environment.

Preserve both upstream entry points, `kaiten` and `kaiten-agent-gateway`, and set `meta.mainProgram = "kaiten"`. Use package import checks and the existing upstream pytest suite. Do not invent a license: the inspected release has no explicit license declaration; leave `meta.license` unset unless upstream evidence establishes one.

Change `overlays/default.nix` into a function taking `{ kaitenCliSrc }` and returning its existing overlay list. Define `pkgs.kaiten-cli` there by passing `src = kaitenCliSrc` to `callPackage`. In `flake.nix`, construct the overlay list once from `inputs.kaiten-cli` and reuse that binding at the two existing host imports. Preserve the Linux-only guard for `kaiten-mcp`.

Expose `packages.<system>.kaiten-cli` on all three existing supported systems: `x86_64-linux`, `aarch64-linux`, and `aarch64-darwin`. Availability as a flake output or overlay attribute is not installation. Home Manager continues using unstable nixpkgs; the ordinary flake package output continues using the existing stable package set.

### Host-scoped Home Manager module

Create `home/software/kaiten-cli/default.nix`, imported by `home/default.nix`, with a default-false `software.kaiten-cli.enable` option. When enabled it owns:

1. `home.packages = [ pkgs.kaiten-cli ]`.
2. `codingAgents.skills.sources.kaiten-cli`, referencing input `"kaiten-cli"` and subdirectory `"skills"`.
3. Exactly these upstream explicit selections:
   - `kaiten-cli-heavy-data`
   - `kaiten-cli-metrics`
   - `kaiten-cli-mutations`

Each explicit selection uses source `"kaiten-cli"`, its matching directory name, and `agents = [ "agents" ]`. Do not add this source to the common `enable` or `enableAll` lists. No content transform, command rewriting, or package symlinks inside skills are needed.

Set `software.kaiten-cli.enable = true` only in the DodoBook inline module in `flake.nix`. The feature relies on that host's already-enabled shared target; do not add `codingAgents.pi`, enable separate `pi`/`codex` deployment targets, or change the existing coding-agent flags.

The resulting additions are:

```text
DodoBook Home Manager profile: bin/kaiten, bin/kaiten-agent-gateway
~/.agents/skills/kaiten-cli-heavy-data/SKILL.md
~/.agents/skills/kaiten-cli-metrics/SKILL.md
~/.agents/skills/kaiten-cli-mutations/SKILL.md
```

The Kaiten directories must be absent from DodoBook's Claude bundle and from both bundles on the other Mac. A shared directory cannot restrict which installed harness reads it: OpenCode or any other consumer of `~/.agents/skills` can also discover these skills. The user has been told this boundary.

## Credentials and activation safety

Leave profiles, API tokens, caches, and snapshots as mutable upstream-managed user state outside Nix and the repository. Package validation must use a temporary home/config, no credentials, no network API requests, and the upstream default `not live` pytest selection. A missing-credentials command must fail cleanly with the documented configuration error, not attempt remote access.

Skills are deployed by the existing managed synchronizer, not competing `home.file` links or a new activation hook. Do not force takeover of a non-empty unmanaged skill directory or delete user files. Actual activation on DodoBook is a later, separately authorized action.

## Acceptance criteria

- The package builds, imports, runs offline help/version/discovery, and passes upstream offline tests on the native build platform.
- Both macOS configurations evaluate and build; DodoBook's Home Manager package comes from the same input as its skill source despite using a different nixpkgs package set from the public output.
- Only DodoBook has the package and Kaiten source/explicit selections enabled.
- Built target bundles contain all three skills only in DodoBook's `agents` target, while existing skills remain present.
- The full existing validation workflow passes, or any platform/builder or pre-existing failure is reported explicitly rather than counted as a pass.
- There are no unrelated dependency updates or changes to existing services, secrets, or agent configuration.

## Evidence and builder latitude

Upstream facts come from the [v0.3.3 package manifest](https://github.com/ViktorOgnev/kaiten-cli/blob/v0.3.3/pyproject.toml), [skills](https://github.com/ViktorOgnev/kaiten-cli/tree/v0.3.3/skills), and the release tag. Per-target selection behavior was checked in the locally locked `agent-skills-nix` module and its `test/home-manager-skill-targets.nix` fixture.

The builder chooses idiomatic Nix formatting and whether to write the three explicit selections literally or with `lib.genAttrs`. The interfaces, host boundary, input strategy, skill names, and target allowlist are fixed. If the pinned upstream tests expose packaging failures, investigate rather than disabling tests or changing the agreed release silently.
