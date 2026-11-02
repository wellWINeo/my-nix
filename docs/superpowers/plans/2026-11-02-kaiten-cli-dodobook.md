# Kaiten CLI on DodoBook Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Delegation requires user authorization; this document does not authorize implementation.

**Goal:** Package Kaiten CLI and install it with its three upstream skills only on DodoBook, with the skills under `~/.agents/skills`.

**Architecture:** A pinned, non-flake `kaiten-cli` input supplies both the Python package source and skill catalog. The existing overlay exposes the package, and one opt-in Home Manager software module owns its installation and target-restricted skill selections. Enable that module only for DodoBook.

**Tech Stack:** Nix flakes, the repository's stable/unstable nixpkgs package sets, Home Manager, Python >= 3.11, Hatchling, pytest, `agent-skills-nix`, `nixfmt`.

**Spec:** [Kaiten CLI and shared skills on DodoBook](../specs/2026-11-02-kaiten-cli-dodobook-design.md). Read it before implementation.

## Global Constraints

- This request authorizes planning and review only. Obtain implementation approval before executing these tasks; do not commit, push, or activate Home Manager unless separately asked.
- Use `inputs.kaiten-cli`, `flake = false`, URL `github:ViktorOgnev/kaiten-cli` without a URL version tag; initial package version is `0.3.3`.
- Pin the initial revision `18abe81aa52ad6a1cec0334452194691b06ad4f4` only in `flake.lock`. Removing the URL tag must not advance that revision or change its hash. Keep every unrelated input pin unchanged.
- Use that same input for package `src` and the skill source. Do not use `fetchFromGitHub` or a second source pin.
- Enable `software.kaiten-cli.enable` only for `o__ni@DodoBook.local`.
- Select exactly `kaiten-cli-heavy-data`, `kaiten-cli-metrics`, and `kaiten-cli-mutations`, each with `agents = [ "agents" ]`.
- Keep the existing shared `agents` destination, `$HOME/.agents/skills`; do not enable native Pi/Codex targets or add agent flags.
- Do not change `kaiten-mcp`, credentials, global instructions, existing service setup, or unrelated dependencies.
- Keep upstream offline tests enabled and live/API tests disabled. Use temporary configuration and no real credentials for smoke checks.
- An untested platform or blocked build is not a successful validation. Do not disable failing tests to obtain a green build.

## Review Focus

1. **Pin or version drift:** package and skill source must resolve to the same locked release; Task 1 checks lock changes and Task 2 checks source identity.
2. **Different Python package sets:** the public output uses stable nixpkgs, while DodoBook uses unstable; Tasks 1 and 3 build both paths and exercise installed entry points/data files.
3. **Wrong skill destination:** common enable-all selection would leak skills to Claude; Task 2 inspects target allowlists and actual target bundles.
4. **Accidental shared installation:** importing a module must not enable it on the other Mac; Task 2 asserts the disabled host has neither package nor Kaiten selections.
5. **Missing credentials or host side effects:** offline commands must not touch real profiles, contact Kaiten, or start the gateway; Task 1 tests discovery and the structured missing-credentials failure in isolation.

---

## File Map

| File | Action and responsibility |
| --- | --- |
| `flake.nix` | Add the source input, inject it into the overlay, preserve host overlay consumers, expose the package, and enable the DodoBook module. |
| `flake.lock` | Add only the new non-flake source and its root input reference. |
| `overlays/default.nix` | Accept `inputs`, select `inputs.kaiten-cli` as the package source, and expose `pkgs.kaiten-cli`, preserving existing packages and platform guards. |
| `pkgs/kaiten-cli/default.nix` | New Python application recipe with offline checks. |
| `home/default.nix` | Import the new opt-in software module. |
| `home/software/kaiten-cli/default.nix` | New module owning package installation and shared-target-only skills. |
| `README.md` | One short DodoBook-specific package/skill note and build/apply distinction. |

The spec and this plan already exist. No changes to the common coding-agent modules, Makefile, CI, or test runner are required. Use existing upstream tests plus the evaluation and built-bundle assertions below; do not create a new testing framework.

## Task 1: Add the pinned source and tested Python package

**Files:** `flake.nix`, `flake.lock`, `overlays/default.nix`, new `pkgs/kaiten-cli/default.nix`.

**Interfaces:**
- Consumes: the release's `pyproject.toml`, `src/kaiten_cli/__init__.py`, `tests/`, `scripts/`, and `.github/` from `inputs.kaiten-cli`.
- Produces: `pkgs.kaiten-cli` and `packages.<system>.kaiten-cli`; recipe arguments include `lib`, `python3Packages`, `src`, `gitMinimal`, `bash`, and `zsh`. The overlay importer takes `{ inputs }`, selects `src = inputs.kaiten-cli` internally, and returns the existing list of overlays.

- [ ] **1. Establish the missing-package baseline.**

Run `nix eval 'path:.#packages.aarch64-darwin.kaiten-cli.version'`. Expected before implementation: a missing-attribute error. Read the actual locked upstream manifest/tests before choosing check dependencies; do not assume the current default branch matches the tag.

- [ ] **2. Add and lock only the Kaiten source.**

Add the input specified in Global Constraints, then run `nix flake lock` without a broad update. Verify the new node and unchanged existing nodes:

```bash
python3 - <<'PY'
import json
import subprocess
from pathlib import Path

old = json.loads(subprocess.check_output(["git", "show", "HEAD:flake.lock"]))["nodes"]
new = json.loads(Path("flake.lock").read_text())["nodes"]
assert set(new) == set(old) | {"kaiten-cli"}
for name, node in old.items():
    expected = node
    if name == "root":
        expected = {**node, "inputs": {**node["inputs"], "kaiten-cli": "kaiten-cli"}}
    assert new[name] == expected, name
assert new["kaiten-cli"]["flake"] is False
assert new["kaiten-cli"]["locked"]["rev"] == "18abe81aa52ad6a1cec0334452194691b06ad4f4"
PY
```

Expected: exit 0. This assumes no commits are created during implementation, as required by this plan. Resolve an unexpected locked-revision change before proceeding.

- [ ] **3. Implement the recipe and overlay wiring.**

Use `python3Packages.buildPythonApplication`, `pname = "kaiten-cli"`, version `0.3.3`, `pyproject = true`, injected `src`, Hatchling as the build backend, and `click`, `httpx`, `platformdirs` as runtime dependencies from the same Python package set. Preserve upstream entry points and set `meta.mainProgram = "kaiten"`; leave an unverified license unset.

Change `overlays/default.nix` to accept `{ inputs }`. Set `src = inputs.kaiten-cli` in its `callPackage` invocation outside the Linux-only `kaiten-mcp` guard. In `flake.nix`, construct `overlays` once with `import ./overlays { inherit inputs; }` and replace the two direct imports in mokosh/veles with that binding. Preserve all existing per-host overlay additions. Add `kaiten-cli = pkgs.kaiten-cli` beside the existing unconditional package output.

- [ ] **4. Add offline build and installed-package checks.**

Use `pytestCheckHook` and the manifest's test dependencies: `pytest-asyncio`, `pytest-cov`, `pytest-timeout`, `pytest-socket`, `pyyaml`, and `respx`. Provide Git, Bash, and Zsh for subprocess/release/completion tests. Retain upstream's socket restrictions and default `not live` marker; do not skip tests merely because packaging exposes a failure.

Set a writable temporary `HOME` and config path for checks and remove inherited `KAITEN_DOMAIN`, `KAITEN_TOKEN`, and `KAITEN_LIVE`. Enable `pythonImportsCheck = [ "kaiten_cli" ]` and installed-output smoke checks, not just source-tree invocation:

- `$out/bin/kaiten --locale en --version` contains `0.3.3`.
- `$out/bin/kaiten --locale en --help`, `--locale ru --help`, `--locale en agent-help`, and `--locale en search-tools cards` exit 0 without credentials. The Russian help checks packaged locale data.
- `$out/bin/kaiten-agent-gateway --help` exits 0 without starting a server.
- With no profiles or credentials, `$out/bin/kaiten --locale en --json --read-only cards list` returns the failure contract below. Capture its exit code explicitly and parse stdout as JSON:

```python
assert returncode == 3
assert payload["success"] is False
assert payload["error"]["type"] == "config_error"
```

Do not run live API probes, start the gateway, or invoke any installer/update manager. Upstream test failures must be investigated and reported, not hidden with blanket exception handling or skips.

- [ ] **5. Build and verify package availability.**

Run `nix build 'path:.#kaiten-cli' --no-link --print-out-paths --print-build-logs` on the native platform. Expected: a store output, passing upstream offline tests/import checks/installed-output smoke checks, and no credential requirement. Inspect the version attribute and evaluate `packages.<system>.kaiten-cli.drvPath` for all three supported systems. Evaluation is not proof of a successful cross-platform build; build Linux outputs only with an available native/remote builder and record any limitation.

## Task 2: Install the package and correctly restricted skills on DodoBook

**Files:** new `home/software/kaiten-cli/default.nix`, `home/default.nix`, DodoBook inline module in `flake.nix`.

**Interfaces:**
- Consumes: Task 1's `pkgs.kaiten-cli` and `inputs.kaiten-cli`, plus the already-imported `agent-skills-nix` Home Manager module.
- Produces: default-false `software.kaiten-cli.enable`; enabled DodoBook package installation; source `codingAgents.skills.sources.kaiten-cli = { input = "kaiten-cli"; subdir = "skills"; }`; three upstream `programs.agent-skills.skills.explicit` entries restricted to target `"agents"`.

- [ ] **1. Run the host-scope assertion before implementing the module.**

Run the following expression now and again after Step 2. Initially it must fail because DodoBook does not enable/install Kaiten; afterward it must return the shown evidence object. Use `path:` so untracked implementation files are included.

```bash
nix eval --impure --json --expr '
  let
    f = builtins.getFlake ("path:" + toString ./.);
    d = f.homeConfigurations."o__ni@DodoBook.local";
    s = f.homeConfigurations."o__ni@Stepans-MacBook-Pro";
    names = [ "kaiten-cli-heavy-data" "kaiten-cli-metrics" "kaiten-cli-mutations" ];
    hasPackage = h: builtins.any (p: (p.pname or "") == "kaiten-cli") h.config.home.packages;
    skills = h: h.config.programs.agent-skills;
  in
  assert (d.config.software.kaiten-cli.enable or false);
  assert hasPackage d;
  assert !(s.config.software.kaiten-cli.enable or false);
  assert !(hasPackage s);
  assert (skills d).sources.kaiten-cli.input == "kaiten-cli";
  assert (skills d).sources.kaiten-cli.subdir == "skills";
  assert toString d.pkgs.kaiten-cli.src == toString f.inputs.kaiten-cli;
  assert !((skills s).sources ? kaiten-cli);
  assert builtins.all (n:
    (skills d).skills.explicit.${n}.from == "kaiten-cli"
    && (skills d).skills.explicit.${n}.path == n
    && (skills d).skills.explicit.${n}.agents == [ "agents" ]
  ) names;
  assert builtins.all (n: !(builtins.hasAttr n (skills s).skills.explicit)) names;
  assert (skills d).targets.agents.enable;
  assert !(skills d).targets.pi.enable;
  assert !(skills d).targets.codex.enable;
  { dodobookOnly = true; sameSource = true; sharedTargetOnly = true; }
'
```

Expected after implementation: `{"dodobookOnly":true,"sameSource":true,"sharedTargetOnly":true}`. A false assertion or missing attribute is failure, not an acceptable warning.

- [ ] **2. Implement the opt-in module and DodoBook enablement.**

Follow `home/software/alacritty/default.nix` for the option/`mkIf` structure. Put the package, source registration, and three explicit selections inside the same `mkIf cfg.enable`. Set each selection's `from`, matching `path`, and `agents` as specified above. Import the module in `home/default.nix`; enable it only in DodoBook's inline module. Do not append Kaiten to the common selection lists or change existing coding-agent flags.

Rerun Step 1 and require the expected result.

- [ ] **3. Build target bundles and assert actual file placement.**

Run in a shell, without activating Home Manager:

```bash
set -eu
for host in 'o__ni@DodoBook.local' 'o__ni@Stepans-MacBook-Pro'; do
  for target in agents claude; do
    bundle=$(nix build --no-link --print-out-paths \
      "path:.#homeConfigurations.\"$host\".config.programs.agent-skills.targetBundlePaths.$target")
    for skill in kaiten-cli-heavy-data kaiten-cli-metrics kaiten-cli-mutations; do
      if [ "$host" = 'o__ni@DodoBook.local' ] && [ "$target" = agents ]; then
        test -f "$bundle/$skill/SKILL.md"
      else
        test ! -e "$bundle/$skill"
      fi
    done
    test -f "$bundle/brainstorming/SKILL.md"
  done
done
```

Expected: exit 0. The existing `brainstorming` skill must remain in all four bundles; this catches accidentally replacing the common selection while adding Kaiten. Also evaluate DodoBook's target destination and require `$HOME/.agents/skills`.

## Task 3: Finish documentation and run the existing validation workflow

**Files:** `README.md`; all five changed/new Nix files and `flake.lock` from Tasks 1 and 2.

**Interfaces:**
- Consumes: the package output and Home Manager module from Tasks 1 and 2.
- Produces: concise user-facing documentation and recorded build/scope verification evidence; not an activated configuration.

- [ ] **1. Document the host and shared-directory boundary.**

Add one short README note naming the DodoBook-only option, installed command, three skills, and shared path. Explain that other consumers of `~/.agents/skills` can discover them too and that profiles/tokens are configured privately outside Nix. Do not add credentials, token-bearing example commands, or a new general setup guide.

- [ ] **2. Format and review intended changes.**

Run `nixfmt` on `flake.nix`, `overlays/default.nix`, `pkgs/kaiten-cli/default.nix`, `home/default.nix`, and `home/software/kaiten-cli/default.nix`, followed by `git diff --check`. Before any eventual commit, run the repository-required full formatting check and resolve unrelated formatting separately rather than silently changing it.

Expected: formatted changes and no whitespace errors. Inspect `git diff -- flake.nix flake.lock overlays/default.nix home/default.nix README.md` and read the new files. Confirm only the intended lock node/reference changed and existing overlay order/platform guards survived.

- [ ] **3. Build both macOS activation packages without switching.**

```bash
nix build 'path:.#homeConfigurations."o__ni@DodoBook.local".activationPackage' --no-link --print-out-paths --print-build-logs
nix build 'path:.#homeConfigurations."o__ni@Stepans-MacBook-Pro".activationPackage' --no-link --print-out-paths --print-build-logs
```

Expected: both succeed on `aarch64-darwin`. This builds the unstable-nixpkgs Home Manager package path as well as checking module compatibility. Confirm `home-path/bin/kaiten` exists in DodoBook's generation and not in the other generation, then repeat offline version/help against DodoBook's built binary with a temporary home/config and no credentials. Do not execute either generation's `activate` script.

- [ ] **4. Run existing repository checks and scope assertions.**

```bash
test -f secrets/secrets.json || make setup-dummy-secrets
make check
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests/vulnerability -v
```

Never overwrite existing unlocked secrets. Rerun Task 2's evaluation and bundle assertions after the final changes. `make check` runs the flake checks, including the existing DNS checks; do not edit or apply DNS declarations. Report the exact command and error if platform/build availability or an unrelated existing failure blocks validation. Do not claim unrun checks passed.

- [ ] **5. Hand back the implementation diff and verification results.**

Run `git status --short --branch` and `git diff --check`. Report the package/source version, host/target isolation results, build/test results, and any platform limitation. Leave changes uncommitted unless the user explicitly asks for a commit.

Actual deployment is deliberately outside this plan's automatic execution. If later authorized on DodoBook, use the existing exact-host Makefile target `make apply:home:o__ni@DodoBook.local`. Inspect any unmanaged skill-directory conflict before activation; never force takeover or delete user data to make deployment succeed.

## Planning Self-Review

- **Spec coverage:** source/overlay/package map to Task 1; host-owned installation and restricted skills map to Task 2; documentation, both package sets, and existing validations map to Task 3.
- **Interfaces:** the overlay's `inputs` argument, `inputs.kaiten-cli`, `pkgs.kaiten-cli`, and `software.kaiten-cli.enable` are used consistently; target names are deployment keys, not harness names.
- **Review focus:** each of the five failure classes above has an owning check; bundle inspection verifies actual installation contents, not only booleans.
- **Scope:** no implementation is included in this planning change, and no new runner, agent namespace, credential store, or activation hook is proposed.
- **Verification status:** commands in this plan are instructions for future implementation, not claims that builds or tests have already run.

## Independent Review

Reviewed on 2026-11-02: no actionable findings; builder-check result was "nothing important left". Verdict: ready as planning documents, without authorizing implementation. The review checked repository wiring and the locked skill-deployment interfaces; it did not execute package/Home Manager builds or the pinned release's smoke commands. Release-tag resolution was checked during planning, not independently repeated by the review.
