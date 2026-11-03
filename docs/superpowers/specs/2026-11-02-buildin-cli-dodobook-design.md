# Buildin CLI and skill on DodoBook

**Date:** 2026-11-02

**Status:** Implemented and reviewed; Home Manager activation has not been performed.

## Intent and scope

Install the Buildin CLI and the upstream `buildin-cli` skill declaratively through Home Manager on `o__ni@DodoBook.local` only. Pi and Codex discover the skill in the existing shared `~/.agents/skills` directory; other agents that read this directory may discover it too. Do not install Pi or Codex, change agent instructions, or deploy the skill to Claude's native target.

Support **only `aarch64-darwin`** in the package and flake package output. Other systems must continue evaluating normally, and the other Mac's Home Manager configuration must not install the package or skill. Package availability as a flake output does not imply installation.

## Sources and packaging

The public [Buildin skill repository](https://github.com/next-space/buildin-skill) contains the skill and its supporting reference files, but not the CLI. The upstream skill says the CLI repository may be private. A search of Next Space's public repositories and Buildin's public documentation did not identify the CLI's source; the public [API SDK](https://github.com/next-space/buildin-api-sdk) is not the CLI. This is not proof that source cannot be found elsewhere. If the official CLI source is found before implementation, stop and reassess the source-build option rather than silently using the binary.

Use the vendor's released `aarch64-darwin` archive, not the installer. At planning time, the official [latest version](https://cdn.buildin.ai/buildin-cli/latest/version) is `v0.3.15`, and the [vendor checksum manifest](https://cdn.buildin.ai/buildin-cli/releases/v0.3.15/SHA256SUMS) lists SHA-256 `ed656d64b34ca6b829b4a375cef6dd3c2ffceebc310e8040bd4bf6f4266e231a` for `buildin-darwin-arm64.tar.gz`. Pin the release URL and hash in `pkgs/buildin-cli/default.nix`, exposing `bin/buildin`. The archive and checksum come from the same CDN; the checksum pins bytes but is not an independent signature.

Register the package through the existing overlay and expose a flake package only for `aarch64-darwin`, guarding evaluation on all other supported systems. Do not claim an unverified license. Nix owns the executable: upgrades require changing the pinned release and checksum, not using `buildin update` to mutate the Nix store.

Add `github:next-space/buildin-skill` as a non-flake input, locked independently from the binary. The investigated revision is `256f9680192521dd71efd6b400c69c06ad96de68`; use this revision for the initial lock. Since binary and skill have separate release mechanisms, check compatibility on updates and do not assume they advance together.

## Home Manager integration

Follow `home/software/kaiten-cli/default.nix`: add a default-off `software.buildin-cli.enable` module, imported by `home/default.nix`, and enable it only in DodoBook's flake configuration. The module installs `pkgs.buildin-cli`, registers the upstream `skills` catalog, and explicitly selects the `buildin-cli` skill for `agents = [ "agents" ]`. Do not add the source to the global skill allowlist or create competing `home.file` links or activation hooks. Preserve all supporting files, including `references/`, via the existing skill machinery.

The shared target is already enabled on DodoBook through OpenCode; do not change tool flags just to expose the skill. Do not perform Home Manager activation as part of this task. Do not overwrite or remove unmanaged user skill directories.

## Credentials, checks, and failure behavior

Keep Buildin login, token, and configuration state outside Nix and the repository. Do not execute the installer, self-updater, login, or live API calls during package tests. Smoke-test `buildin version` and `buildin --help` with a temporary home and no credentials, and check that an unauthenticated identity request fails cleanly without network access if the binary permits an offline test. A failure must not expose credentials or trigger login.

Verify both macOS Home Manager configurations, actual shared and Claude skill bundles, presence of supporting references, and exclusion on the other Mac. Run the repository's existing flake checks and tests; report unavailable builders or failures rather than claiming success. Actual login and deployment require separate authorization.
