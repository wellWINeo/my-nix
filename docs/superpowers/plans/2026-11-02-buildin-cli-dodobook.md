# Buildin CLI on DodoBook Implementation Plan

> **For agentic workers:** Use the executing-plans skill for inline execution or, if explicitly authorized, the subagent-driven-development skill. Steps use checkbox syntax. Activation requires separate authorization.

**Goal:** Install the pinned Buildin CLI and its upstream skill on DodoBook through Home Manager, with the skill available to Pi and Codex.

**Architecture:** Package the official macOS ARM release archive using a fixed-output hash and register the package in the existing platform-guarded overlay. A separately pinned non-flake input supplies the skill; a DodoBook-only software module installs the package and selects the skill for the existing shared agent target.

**Tech Stack:** Nix flakes, Home Manager, `agent-skills-nix`, `nixfmt`, vendor-provided macOS ARM binary.

**Spec:** [Buildin CLI and skill on DodoBook](../specs/2026-11-02-buildin-cli-dodobook-design.md). Read it before implementation.

## Global Constraints

- Implementation was authorized after planning; activation requires separate authorization.
- Package only `aarch64-darwin`; expose the flake package only on that platform. Other system evaluations must not force the unsupported package.
- Initial CLI version is `v0.3.15`, archive `https://cdn.buildin.ai/buildin-cli/releases/v0.3.15/buildin-darwin-arm64.tar.gz`, SHA-256 `ed656d64b34ca6b829b4a375cef6dd3c2ffceebc310e8040bd4bf6f4266e231a`.
- Use the separately locked non-flake input `github:next-space/buildin-skill`, initially at revision `256f9680192521dd71efd6b400c69c06ad96de68`; do not update unrelated inputs.
- Install package and skill only on DodoBook. Select `buildin-cli` only for the shared `agents` target, not Claude's native target.
- Credentials stay outside Nix. Do not run the installer, self-updater, login, live API requests, or Home Manager activation.
- Do not claim that unavailable checks passed, invent a license, or force takeover of existing skill directories.

## Review Focus

1. **Unpublished source:** recheck the official upstream source and stop if CLI source is available; do not confuse the API SDK with the CLI (Task 1).
2. **Corrupt or changed release:** verify archive bytes against the vendor manifest and exercise Nix's fixed hash; a mismatch must fail the fetch (Task 1).
3. **Unsupported systems:** non-Darwin flake outputs and configurations must continue evaluating and must not expose this macOS-only package (Task 1).
4. **Incorrect host or target:** verify the package and complete skill only appear on DodoBook and its shared target; preserve existing skills (Task 2).
5. **Sensitive state and network:** offline checks use an empty temporary home and no token; verify failure behavior without logging in or sending a remote API request (Task 1).

## File Map

| File | Responsibility |
| --- | --- |
| `flake.nix` | Add the skill input, macOS ARM package output, and DodoBook-only opt-in. |
| `flake.lock` | Pin the skill input without advancing other inputs. |
| `overlays/default.nix` | Expose the package only on `aarch64-darwin`. |
| `pkgs/buildin-cli/default.nix` | Pin and install the vendor archive; run offline checks. |
| `home/default.nix` | Import the opt-in software module. |
| `home/software/buildin-cli/default.nix` | Own the package and the shared-target-only skill selection. |
| `README.md` | Briefly document DodoBook availability, shared discovery, updates, and private credentials. |

## Task 1: Package the official macOS ARM CLI

**Files:** `flake.nix`, `overlays/default.nix`, new `pkgs/buildin-cli/default.nix`.

**Interfaces:** Produces `pkgs.buildin-cli` and `packages.aarch64-darwin.buildin-cli`; executable is `bin/buildin`. The package and output must not be present on the other supported systems.

- [ ] **1. Establish the baseline and recheck source availability.**

Run `nix eval 'path:.#packages.aarch64-darwin.buildin-cli.version'`; before implementation it must fail with a missing-attribute error. Recheck [Next Space's public repositories](https://github.com/orgs/next-space/repositories), the [skill](https://github.com/next-space/buildin-skill), and official CLI distribution for an actual CLI source repository. If found, stop and discuss source packaging; the public API SDK is not the CLI.

- [ ] **2. Verify the release evidence.**

Fetch the versioned vendor `SHA256SUMS` manifest and confirm its `buildin-darwin-arm64.tar.gz` entry matches Global Constraints. Check the downloaded archive's SHA-256 before inspecting the archive layout. Do not execute the installer or archive binary during inspection. If the bytes or manifest differ, stop rather than silently changing the pin.

- [ ] **3. Implement the guarded binary derivation and flake output.**

In `pkgs/buildin-cli/default.nix`, use `fetchurl` with the exact versioned archive and fixed hash, and a Nix derivation that installs the archive's `buildin` executable as `$out/bin/buildin`. Set `meta.mainProgram = "buildin"` and `meta.platforms = [ "aarch64-darwin" ]`; leave an unverified license unset. Use the archive's actual layout and preserve executable permissions.

Register `buildin-cli` through `callPackage` in the existing overlay only when `prev.stdenv.hostPlatform.system == "aarch64-darwin"`. Expose it in `flake.nix` only when `system == "aarch64-darwin"`, preserving all existing overlays and package outputs. Nix's fixed hash must reject mismatched archive bytes.

- [ ] **4. Build and exercise offline behavior.**

Run `nix build 'path:.#packages.aarch64-darwin.buildin-cli' --no-link --print-out-paths --print-build-logs` on a native macOS ARM builder. With a fresh temporary `HOME` and `BUILDIN_CONFIG_DIR`, unset `BUILDIN_TOKEN`, `BUILDIN_BASE_URL`, and other credential-related variables, then run the installed `bin/buildin version` and `bin/buildin --help`. Both must exit 0; version output must identify `0.3.15`.

Also test a missing-credentials operation only if it can be run with network access blocked: it must fail without starting login or exposing credentials. If the tool cannot enforce network isolation, report this check as unrun rather than making an API call. Never run `buildin update`.

- [ ] **5. Check platform isolation and hash enforcement.**

Evaluate the package attribute names for `aarch64-darwin`, `aarch64-linux`, and `x86_64-linux`, and assert `buildin-cli` is present only on `aarch64-darwin`. Evaluate the existing NixOS configurations and both Home Manager configurations to catch eager references to the unsupported overlay attribute. Test a deliberately incorrect fixed hash in a temporary, out-of-repository expression: the fetch must fail with a hash mismatch. Do not alter the real package pin to perform the negative check.

## Task 2: Add DodoBook-only shared skill deployment

**Files:** `flake.nix`, `flake.lock`, `home/default.nix`, new `home/software/buildin-cli/default.nix`.

**Interfaces:** Consumes Task 1's `pkgs.buildin-cli` and `inputs.buildin-skill`. Produces default-false `software.buildin-cli.enable`, `codingAgents.skills.sources.buildin-skill`, and `programs.agent-skills.skills.explicit.buildin-cli` restricted to `[ "agents" ]`.

- [ ] **1. Lock the skill and verify the intended source.**

Add `buildin-skill = { url = "github:next-space/buildin-skill"; flake = false; };` in `flake.nix`. Lock revision `256f9680192521dd71efd6b400c69c06ad96de68` using the lock file, not an unpinned runtime fetch. Compare `flake.lock` with its pre-change state: only the new input node and root reference may change. Inspect the locked `skills/buildin-cli/SKILL.md` and both referenced Markdown files; confirm the skill still describes the installed CLI's commands.

- [ ] **2. Establish a failing host-scope assertion.**

Run the following before and after implementation. Before implementation, DodoBook's enabled/package assertion must fail; afterward the expression must print `true`:

```bash
nix eval --impure --json --expr '
  let
    f = builtins.getFlake ("path:" + toString ./.);
    d = f.homeConfigurations."o__ni@DodoBook.local".config;
    s = f.homeConfigurations."o__ni@Stepans-MacBook-Pro".config;
    hasPackage = c: builtins.any (p: (p.pname or "") == "buildin-cli") c.home.packages;
    a = d.programs.agent-skills;
  in
  assert (d.software.buildin-cli.enable or false);
  assert hasPackage d;
  assert !(s.software.buildin-cli.enable or false);
  assert !(hasPackage s);
  assert a.sources.buildin-skill.input == "buildin-skill";
  assert a.sources.buildin-skill.subdir == "skills";
  assert a.skills.explicit.buildin-cli.from == "buildin-skill";
  assert a.skills.explicit.buildin-cli.path == "buildin-cli";
  assert a.skills.explicit.buildin-cli.agents == [ "agents" ];
  assert !(s.programs.agent-skills.sources ? buildin-skill);
  assert !(s.programs.agent-skills.skills.explicit ? buildin-cli);
  assert a.targets.agents.enable;
  true
'
```

- [ ] **3. Implement the opt-in module.**

Mirror `home/software/kaiten-cli/default.nix`: under `mkIf cfg.enable`, install `pkgs.buildin-cli`, register input `buildin-skill` with subdirectory `skills`, and select `buildin-cli` explicitly from that source with `path = "buildin-cli"` and `agents = [ "agents" ]`. Import the module in `home/default.nix`; enable `software.buildin-cli.enable = true` only on DodoBook in `flake.nix`. Do not modify the shared global allowlists or tool flags. Rerun Step 2 and require `true`.

- [ ] **4. Verify actual bundle contents and scope.**

```bash
set -eu
for host in 'o__ni@DodoBook.local' 'o__ni@Stepans-MacBook-Pro'; do
  for target in agents claude; do
    bundle=$(nix build --no-link --print-out-paths \
      "path:.#homeConfigurations.\"$host\".config.programs.agent-skills.targetBundlePaths.$target")
    if [ "$host" = 'o__ni@DodoBook.local' ] && [ "$target" = agents ]; then
      test -f "$bundle/buildin-cli/SKILL.md"
      test -f "$bundle/buildin-cli/references/block-own-text.md"
      test -f "$bundle/buildin-cli/references/native-database-fields.md"
    else
      test ! -e "$bundle/buildin-cli"
    fi
    test -f "$bundle/brainstorming/SKILL.md"
  done
done
```

Expected: exit 0. Evaluate DodoBook's `programs.agent-skills.targets.agents.dest` and verify it resolves to the existing shared `~/.agents/skills` location. This verifies bundles without activating or modifying user directories.

## Task 3: Document and validate

**Files:** `README.md` and all files from Tasks 1–2.

**Interfaces:** Consumes both prior tasks; produces documentation and verification evidence, not an activated configuration.

- [ ] **1. Add a concise README note.**

Describe DodoBook's `software.buildin-cli.enable`, `buildin` executable, `buildin-cli` skill and shared directory. Note that other shared-directory consumers may see the skill, credentials remain private outside Nix, and updates require changing the Nix package pin and/or skill lock independently. Do not suggest `buildin update` for the immutable Nix installation.

- [ ] **2. Format and inspect the change.**

Run `nixfmt` on changed Nix files, `git diff --check`, and inspect the diff and new files. Ensure no unrelated lock nodes or credentials changed.

- [ ] **3. Build both macOS Home Manager generations without switching.**

```bash
nix build 'path:.#homeConfigurations."o__ni@DodoBook.local".activationPackage' --no-link --print-out-paths --print-build-logs
nix build 'path:.#homeConfigurations."o__ni@Stepans-MacBook-Pro".activationPackage' --no-link --print-out-paths --print-build-logs
```

Expected: both builds succeed on an ARM Mac. Check the built DodoBook profile contains `bin/buildin`, that the other profile does not, and run offline `version` and `--help` from DodoBook's built profile with an isolated empty home. Do not run either activation script. Repeat Task 2's scope and bundle checks.

- [ ] **4. Run repository checks.**

```bash
test -f secrets/secrets.json || make setup-dummy-secrets
make check
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests/vulnerability -v
```

Never overwrite existing unlocked secrets. `make check` includes existing DNS checks; do not edit or apply DNS. Report exact failures or missing builders rather than calling incomplete verification a pass.

- [ ] **5. Hand off results.**

Report the CLI version, skill revision, verification results, and any limitations. Leave work uncommitted and do not activate Home Manager unless explicitly requested later. If activation is subsequently authorized, inspect any unmanaged skill-directory conflict; never force takeover or delete existing files.

## Planning Self-Review

- The scope is limited to a macOS ARM package and DodoBook-only installation; source and vendor binary are distinct pins.
- Existing skills integration and shared target are reused; no new agent-specific settings or activation hooks are introduced.
- The negative hash, unsupported-system, target isolation, and no-credentials checks cover the main failure cases; network-isolated identity testing is conditional on an actual isolation mechanism.
- Verification steps are future instructions, not claims that the package, builds, or tests have already been run.
