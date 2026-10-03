# Proxy VPS Provisioning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install Buyan, Veles, or the new Timeweb proxy host Stribog from a NixOS live ISO with one guarded `make provision` invocation; only Stribog is installed during the pilot.

**Architecture:** Disko layouts are part of each host's flake configuration and become the source of truth for installation and subsequent NixOS boots. A local Bash wrapper validates the selected target, stages the existing file secrets, and invokes nixos-anywhere in two phases so the 1 GiB installer can use a swapfile before building the full system. A separate on-demand dev shell provides nixos-anywhere on macOS.

**Tech Stack:** Nix flakes (nixos-26.05), Disko, nixos-anywhere from pinned nixpkgs, Bash, OpenSSH, Make, existing GPG secret files. No Ansible or new test framework.

**Spec:** `docs/superpowers/specs/2026-10-03-proxy-vps-provisioning-design.md`

## Global Constraints

- Target hosts: `buyan`, `veles`, `stribog` only. Real installation during the pilot: `stribog` only; do not switch or repartition live Buyan/Veles.
- BIOS/GRUB and ext4 only. Buyan: `/` = `NIXROOT`, `/nix` = `NIXSTORE`; Veles/Stribog: `/` = `NIXROOT`; all use a 2 GiB `/.swapfile`.
- Buyan keeps its existing static `ens3` network config; Veles/Stribog use DHCP. Stribog has Buyan's proxy roles, not Veles's relay/MTProxy/forwarder.
- Use the existing shared Reality key. Keep the existing `secrets.json` and unlocked-file practices; do not claim that `path:.` excludes decrypted secrets from Nix store.
- `provision/image/` and `images/do-generic/` are not changed. No DNS/provider API work, no Pi or Mokosh support.
- No real-host destructive command without explicit new approval from the owner. Never commit or push under this request; before any later commits, follow the repository's branch/worktree decision tree.

## File map

- `flake.nix`, `flake.lock`: Disko input, host modules, Stribog output, on-demand provision shell.
- `machines/{buyan,veles}/default.nix`, new `machines/{buyan,veles}/disk.nix`: Disko-based filesystem/BIOS boot definitions without changing effective running mounts or networking.
- New `machines/stribog/default.nix`, `machines/stribog/disk.nix`: complete host config and Timeweb disk layout.
- `secrets/unlocked/spec.txt`: allow Stribog to receive the existing Reality key. No new private key or decrypted secret committed.
- New `provision/install.sh`: host/secret/disk checks, fingerprint gate, confirmation, two-phase installer, recovery entry point, post-boot checks.
- New `provision/tests/test-install.sh`: minimal Bash regressions for safe refusal and secret selection.
- `Makefile`, `README.md`: on-demand entry point and operator instructions.

---

### Task 1: Make Buyan and Veles installable with Disko without altering their runtime behavior

**Files:** Modify `flake.nix`, `flake.lock`, `machines/buyan/default.nix`, `machines/veles/default.nix`; create `machines/buyan/disk.nix`, `machines/veles/disk.nix`.

**Interfaces:** Produce `nixosConfigurations.<host>.config.disko.devices.disk.main.device` and `.config.system.build.diskoScript` for `buyan` and `veles`; subsequent tasks rely on both.

- [ ] **Step 1: Record the current outputs before editing.** With a locally available `secrets/secrets.json` (do not overwrite a real decrypted file), run:

  ```bash
  for h in buyan veles; do
    nix eval --json "path:.#nixosConfigurations.$h.config.fileSystems" > "/tmp/$h-filesystems-before.json"
    nix eval --json "path:.#nixosConfigurations.$h.config.boot.loader.grub.device" > "/tmp/$h-grub-device-before.json"
    nix eval --json "path:.#nixosConfigurations.$h.config.boot.loader.grub.devices" > "/tmp/$h-grub-devices-before.json"
    nix eval --json "path:.#nixosConfigurations.$h.config.networking" > "/tmp/$h-network-before.json"
  done
  nix eval --raw 'path:.#nixosConfigurations.buyan.config.system.build.diskoScript.drvPath'
  ```

  Expected: the final command fails because Disko is not yet wired; the baseline commands succeed. Do not print secret-bearing networking output in a shared log.

- [ ] **Step 2: Add the pinned Disko input and import its module for Buyan and Veles.** Use `disko.url = "github:nix-community/disko"; disko.inputs.nixpkgs.follows = "nixpkgs";` in `flake.nix`, add `inputs.disko.nixosModules.disko` to the two `modules` arrays, and run `nix flake lock` once. Review the `flake.lock` diff and retain only the intended new Disko input and its dependencies.

- [ ] **Step 3: Add host-owned Disko layouts.** In each `disk.nix`, define `disko.devices.disk.main` with `type = "disk"`, `device = "/dev/vda"` for Buyan or `"/dev/sda"` for Veles, and a GPT `content` with a 1 MiB `EF02` BIOS boot partition. Set a GPT partition priority/order explicitly so it precedes the ext4 partitions. For Veles, root consumes the remainder; for Buyan, root is `8G` and `/nix` uses the rest, with a 16 GiB minimum-disk preflight in Task 5. Disko's GPT partition `size` accepts fixed sizes or `100%`, not `50%`. Format ext4 with `extraArgs = [ "-L" "NIXROOT" ]` (and `NIXSTORE` for Buyan), mounting at `/` and `/nix` respectively. Use the same label constant for the format argument and an explicit `fileSystems."/".device = lib.mkForce "/dev/disk/by-label/NIXROOT"` (and equivalent `/nix`): Disko normally emits a partition path, whereas the current runtime modules use filesystem labels. Disko's GPT module currently adds the containing disk to `boot.loader.grub.devices` when it finds an `EF02` partition. Verify this behavior against the newly pinned Disko source and evaluated host outputs. Both the old singular `grub.device` and the effective plural `grub.devices` were recorded before editing; removing the singular option is acceptable only if the effective `devices` list remains the same nonempty disk path. If the pinned Disko does not generate it, explicitly set `grub.devices` in `disk.nix` using that host's `disko.devices.disk.main.device`, then re-check all three host outputs before proceeding. Example of the root filesystem fragment:

  ```nix
  let rootLabel = "NIXROOT"; in {
    disko.devices.disk.main.content.partitions.root.content = {
      type = "filesystem";
      format = "ext4";
      extraArgs = [ "-L" rootLabel ];
      mountpoint = "/";
    };
    fileSystems."/".device = lib.mkForce "/dev/disk/by-label/${rootLabel}";
  }
  ```

  Import `./disk.nix` in each host module, remove its old `fileSystems` block and `boot.loader.grub.device` assignment only after Disko produces the same effective mount/boot settings. Keep the existing swapfile declaration and networking unchanged. If `disko` generates additional boot settings or different mount options, resolve the difference explicitly rather than weakening the comparison.

- [ ] **Step 4: Verify both configs.** Run the Disko output evaluation again and compare the baseline mount, GRUB, and network values; only intentional Disko metadata may differ. Run `nixfmt` on changed Nix files and `make check`. Expected: both new Disko scripts evaluate; existing Buyan/Veles still use the same label paths, effective nonempty GRUB installation target (compare both baseline `device` and `devices`), network mode, and swapfile. A mismatch stops implementation before proceeding.

### Task 2: Add Stribog as a full proxy host

**Files:** Create `machines/stribog/default.nix`, `machines/stribog/disk.nix`; modify `flake.nix`, `secrets/unlocked/spec.txt`.

**Interfaces:** Produce `nixosConfigurations.stribog`, a Disko root labeled `NIXROOT` on `/dev/sda`, and an SSH-accessible `o__ni` after install. Task 3's wrapper uses this flake attribute and the spec entry.

- [ ] **Step 1: Assert the current missing host.** Run `nix eval --raw 'path:.#nixosConfigurations.stribog.config.networking.hostName'`. Expected: missing attribute before any changes.

- [ ] **Step 2: Add the host and disk declarations.** Copy only Buyan's proxy-service settings (Xray server TCP/gRPC/XHTTP with its SNIs, SNI-router redirect, metrics, hardened role, observability agent, Tailscale/Headscale, SSH policy) into `machines/stribog/default.nix`. Set `hostname = "stribog"`, `users = filterProxyUsersForHost hostname secrets.singBoxUsers`, `networking.useDHCP = true`, Timeweb guest services and `boot.kernel.sysctl."net.ipv6.conf.all.disable_ipv6" = 1` from Veles (the provider's IPv6 performance workaround), `swapDevices = [ { device = "/.swapfile"; size = 2 * 1024; } ];`, and `system.stateVersion = "26.05"`. Import `../../common/{cache,hardened,server}.nix` as separate paths, `../../hardware/vm.nix`, `../../roles`, and `./disk.nix`. Make `disk.nix` the Veles-style BIOS GPT layout on `/dev/sda`, with root ext4 `NIXROOT`. Wire the flake output with `inputs.disko.nixosModules.disko`, the existing Xray overlay, and `./users/o__ni`; do not add Telemt/relay overlays.

  ```nix
  nixosConfigurations."stribog" = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = inputs;
    modules = [
      { nixpkgs.overlays = [ xrayOverlay ]; }
      inputs.disko.nixosModules.disko
      ./machines/stribog
      ./users/o__ni
    ];
  };
  ```

  Append `stribog:xray-reality-private-key:0400:root:root` to `secrets/unlocked/spec.txt`; do not create or duplicate the source key. Keep other roles and secret files identical to Buyan only where actually used.

- [ ] **Step 3: Verify happy and failure modes.** Evaluate the hostname, DHCP, `fileSystems."/".device`, BIOS GRUB disk, three Xray transports, agent, and Tailscale. Test with `secrets/secrets.dummy.json` only when no real `secrets.json` exists; its `hosts = "*"` proxy user must appear on Stribog, while its Veles-only entry must not. Temporarily test the filter as a pure Nix function with only `hosts = "buyan"` and assert the Stribog result is empty, then restore the input used for validation. Run `nixfmt` and `make check`. An empty real Stribog user list must be detected before any destructive provisioning.

### Task 3: Add the opt-in provisioning shell and Make entry point

**Files:** Modify `flake.nix`, `Makefile`; begin `provision/install.sh`.

**Interfaces:** `make provision HOST=stribog IP=<ISO-IP>` runs `nix develop .#provision -c ./provision/install.sh`; the script reads `HOST` and `IP` from the exported Make environment, never from interpolated shell text.

- [ ] **Step 1: Confirm the shell is currently missing.** `nix eval --raw 'path:.#devShells.aarch64-darwin.provision.drvPath'` must fail before editing.
- [ ] **Step 2: Add an independent `devShells.<system>.provision` to the existing `forAllSystems` expression:**

  ```nix
  provision = pkgs.mkShell {
    nativeBuildInputs = [ pkgs.nixos-anywhere ];
  };
  ```

  Do not add nixos-anywhere to `devShells.default`. Add a `provision` Make target whose recipe is `nix develop .#provision -c ./provision/install.sh` with no Make-time `$(HOST)`/`$(IP)` interpolation (command-line Make variables are exported as environment variables). Start the Bash script with `set -euo pipefail`, a supported-host allowlist, and required variable checks before touching SSH or disks.

- [ ] **Step 3: Validate.** `nix eval --raw 'path:.#devShells.aarch64-darwin.provision.drvPath'` succeeds, `nix eval --raw 'path:.#devShells.aarch64-darwin.default.drvPath'` still succeeds, and `bash -n provision/install.sh` passes. Running `make provision HOST=unknown IP=127.0.0.1` must reject the host before starting SSH, Nix builds, or Disko. Run `nix develop .#provision -c nixos-anywhere --help` and confirm that this pinned version supports `--build-on remote`, `--phases disko`, `--phases install,reboot`, `--target-host`, and `--extra-files` before writing the wrapper.

### Task 4: Validate and stage only the secrets the proxy hosts actually need

**Files:** Modify `provision/install.sh`; create `provision/tests/test-install.sh`.

**Interfaces:** `required_secrets(host)` returns Buyan/Stribog's `xray-reality-private-key`, `tailscale-auth-key`; Veles also needs `hysteria-veles-key`, `hysteria-veles-cert`. `stage_secrets(host, source_dir, spec_path, target_dir)` verifies every required host/`*` spec row and copies only these files to `target_dir/etc/nixos/secrets` with declared modes. Tasks 5–6 consume the staged tree.

- [ ] **Step 1: Write a failing Bash test.** Source the script without executing `main` when sourced. Create a temporary fixture with a dummy `spec.txt`, two required files, and one unrelated wildcard file; assert staging Stribog copies exactly the two required files with mode `0400`, not the wildcard. Remove a required file and assert staging fails with no partial target tree used for installation. Assert `veles:cloudflare.ini` is not selected: Veles does not enable ACME and has no `acme` account. Use `mktemp -d`, `trap`, `test -f`, and portable permission checks for the macOS controller. Do not write actual credentials into the fixture.

- [ ] **Step 2: Verify the new test fails because `stage_secrets` is not implemented.** Run `bash provision/tests/test-install.sh`; expected: nonzero from the missing function or incorrect selection.

- [ ] **Step 3: Implement minimal staging.** Validate `HOST`, `IP`, `secrets/secrets.json`, `secrets/unlocked/spec.txt`, and each required unlocked file before partitioning. Parse `spec.txt` as `host:filename:perm:owner:group`, require exactly one matching row per required name (`HOST` preferred over `*` if both exist), reject filename path traversal, and reject conflicting duplicates. Allocate a local directory with `umask 077` and `mktemp -d`; populate `etc/nixos/secrets/` using `install -m "$perm"`. The selected entries for these three proxy hosts must all be owned `root:root`; fail before Disko if this is not true instead of silently losing ownership through nixos-anywhere's root-owned copy. Clean up the staged directory with an EXIT trap. Never print file contents or invoke `set -x`. Pre-evaluate the selected full system and require at least one filtered Xray user, without dumping the user records.

  ```bash
  case "$host" in
    buyan|stribog) required=(xray-reality-private-key tailscale-auth-key) ;;
    veles) required=(xray-reality-private-key tailscale-auth-key hysteria-veles-key hysteria-veles-cert) ;;
    *) return 1 ;;
  esac
  ```

- [ ] **Step 4: Verify tests now pass.** Run `bash provision/tests/test-install.sh`, `bash -n provision/install.sh`, and `make check`; check `git status --short` for accidental plaintext artifacts. Expected: required files staged, missing file and invalid spec rejected before any SSH/disk command.

### Task 5: Guard the installer and orchestrate Disko, swap, install, and recovery

**Files:** Modify `provision/install.sh`, `provision/tests/test-install.sh`.

**Interfaces:** Normal mode installs only after fingerprint, hardware, and typed wipe confirmation; `--resume-install` skips Disko and requires the target root already mounted at `/mnt`. `nixos-anywhere --extra-files` consumes Task 4's directory in the install phase.

- [ ] **Step 1: Write failure tests before implementation.** With fixture `ssh`/`nixos-anywhere` binaries earlier on `PATH`, simulate UEFI (`/sys/firmware/efi` present via the SSH stub), wrong disk/type, untrusted ISO fingerprint, missing secret, and mismatched confirmation; in each case assert the stub log contains no `disko` or `install` phase invocation. A happy dry fixture (correct BIOS, disk type/size, matching fingerprint/confirmation) must authorize the root key on the live ISO and invoke `disko` before `install,reboot`. A `--resume-install` fixture must not invoke Disko. Stub only executables in the test process, never a real host. Baseline: tests fail before orchestration exists.

- [ ] **Step 2: Implement preflight and confirmation.** Accept only `HOST=buyan|veles|stribog` and a valid IP, obtain the target disk from the evaluated `config.disko.devices.disk.main.device`, and query the live ISO for BIOS/UEFI, `lsblk` whole-disk type, size and partitions. Require at least 16 GiB total for Buyan (8 GiB root, remaining `/nix`) and 8 GiB for Veles/Stribog (single root); both leave room for the 2 GiB swapfile. Refuse smaller disks rather than guessing a partition size. Fail before Disko on a mismatch. Ask the operator for the ISO's ED25519 host-key SHA256 fingerprint as read via the provider console, compare it with a fresh SSH key scan, and refuse mismatch. Use the checked key in an independent strict SSH preflight. Note: nixos-anywhere itself sets `StrictHostKeyChecking=no`, so the preflight is not a per-connection guarantee. Ask for the exact host and disk path as separate typed confirmations immediately before Disko.

- [ ] **Step 3: Invoke the remote installer in two phases.** Generate a single temporary ED25519 installer key (`ssh-keygen`) and reuse it in both invocations. Before the first nixos-anywhere invocation, connect to `nixos@$IP` with the ISO's manually set short-lived password, install the generated public key in `/root/.ssh/authorized_keys` using `sudo` without overwriting existing keys, and verify `ssh -i "$installer_key" root@$IP true` succeeds. Do not invoke the installer if it fails. Call `nixos-anywhere` from the provision shell with `-i "$installer_key" --build-on remote --flake "path:.#$HOST" --target-host "root@$IP" --phases disko`; the machine is already booted into the installer, so no kexec phase is needed. After Disko, confirm `/mnt` contains the intended root; create a 2 GiB `/mnt/.swapfile` with mode `0600`, `mkswap`, and `swapon` through SSH. Call `nixos-anywhere -i "$installer_key" --build-on remote --flake "path:.#$HOST" --target-host "root@$IP" --phases install,reboot --extra-files "$staged_dir"`. Do not call Disko again if the install phase fails. On success verify SSH connectivity as `o__ni`, `findmnt /`, swap, and the relevant service status; if the post-reboot host key changed, require operator verification instead of silently disabling checking.

- [ ] **Step 4: Add an explicit non-destructive recovery mode.** `--resume-install` verifies that the ISO is still booted, the target root is already mounted at `/mnt`, and the target disk matches; it repeats staging, the password-authenticated root SSH-key bootstrap, swap activation if required, and **only** `--phases install,reboot`. It refuses to repartition. Document the recovery prerequisite of accessing the provider console if ISO SSH is lost. It also requires fingerprint verification before reconnecting; do not silently trust a replacement key.

- [ ] **Step 5: Verify focused behavior.** Run `bash provision/tests/test-install.sh`, `bash -n provision/install.sh`, and `make check`. Inspect the stub command log to verify no secrets appear and no failed-preflight path reaches Disko. Do not run the happy path against a real IP in automated tests.

### Task 6: Operator documentation, final static validation, and separately approved pilot

**Files:** Modify `README.md` and (only if test findings require it) the plan/spec. Do not change `provision/image/` or `images/do-generic/`.

- [ ] **Step 1: Document operator workflow.** Describe preparing the NixOS live ISO (network, `passwd nixos`, console-confirmed SSH fingerprint), locally decrypting existing secrets (`make unlock` only if the files are not already unlocked), running `make provision HOST=stribog IP=<ISO-IP>`, the irreversible disk/hostname confirmation, `--resume-install`, the installed `o__ni` SSH login, and the two SSH host-key transitions. Add `stribog` to the README Machines table and directory listing. Document post-failure inspection of the live ISO's mounts and install logs before using resume mode. Explicitly say that `nixos-anywhere` disables host-key verification internally and that decrypted secrets are already included in `path:.` snapshots. Note that Buyan and Veles are configured but not deployed or runtime-tested.

- [ ] **Step 2: Run the project checks and inspect the diff.** Execute `nixfmt` on every changed Nix file, `bash provision/tests/test-install.sh`, `bash -n provision/install.sh`, and `make check` (without replacing a real decrypted secrets file). Evaluate all three host outputs and Disko disk devices, inspect `git diff --check` and `git status --short`, and verify the only secret-spec change adds the Stribog Reality key line. If an x86_64 Linux VM/builder is available, confirm the pinned Disko module exposes `system.build.installTest` for Stribog, then run that test; otherwise explicitly record that it was not run. Check the runtime modes of `--extra-files` copies on the pilot host, since the wrapper's local staging checks alone cannot prove how the remote tar extraction handles modes.

- [ ] **Step 3: Request separate authorization for real destructive testing.** Do not run `make provision` against a VPS as part of implementing this plan. If the owner approves the pilot, run it only on a disposable `stribog` Timeweb VPS, confirm SSH, DHCP, mounts, swap, mode/ownership of required secret files, Xray and SNI-router health, metrics agent, and Tailscale. No `buyan`/`veles` deployment until another approval.

**Handoff:** Stop after implementation and checks; report the plan/spec paths, any unchecked VM/live-host scenarios, and any security or disk-layout deviations. Do not commit or push unless separately asked and on an approved feature branch/worktree.
