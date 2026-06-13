# DigitalOcean image for mokosh — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a generic DigitalOcean-bootable qcow2 image to this flake and stage the mokosh-side changes needed to run on the droplet, so mokosh can be migrated to DO via `make switch` after first boot.

**Architecture:** A new `images/do-generic/` module defines DO hardware + cloud-init networking + growpart. A new `nixosConfigurations.do-generic` assembles it with the existing `common/cache.nix`, `common/server.nix`, and `users/o__ni`. A new flake package `do-image` exposes its `system.build.digitalOceanImage`. The mokosh machine config is updated on this branch to drop static IP and import the same image module, but the branch is not merged until cutover.

**Tech Stack:** NixOS (nixos-25.11), Nix flakes, upstream `nixos/modules/virtualisation/digital-ocean-image.nix`, cloud-init (NixOS module), QEMU for smoke test.

**Branch:** `feat/mokosh-do-image` (already created, spec committed there).

**Background context for the implementer:**
- This repo's "tests" are `nix flake check` (evaluates every `nixosConfigurations.*` and `packages.*`) and `nix build .#<attr>` (actually realizes the derivation). There is no unit test framework. Treat eval/build success + QEMU smoke as the verification step at the end of each task.
- The repo uses `nixfmt-rfc-style` (available in `nix develop`). Run `make fmt` before committing.
- Don't commit `result/` symlinks or build outputs.
- The on-prem mokosh must keep working until cutover. The mokosh-side change is on this branch only and **must not be merged to main** until the droplet is verified.
- Read the spec at `docs/superpowers/specs/2026-06-06-mokosh-do-image-design.md` before starting if you have not.

---

## File structure

| Path | Action | Responsibility |
|---|---|---|
| `images/do-generic/default.nix` | create | DO hardware profile: image builder import, cloud-init networking, growpart, virtio modules, GRUB on `/dev/vda`. No users, no roles. |
| `flake.nix` | modify | Add `nixosConfigurations.do-generic` and `packages.<system>.do-image`. |
| `README.md` | modify | Add a short "Bootstrapping a DigitalOcean droplet" subsection. |
| `machines/mokosh/default.nix` | modify | Replace `hardware/vm.nix` import with `images/do-generic`; drop static IP block; keep hostname. **Branch only — do not merge until cutover.** |

---

## Task 1: Create `images/do-generic/default.nix`

**Files:**
- Create: `images/do-generic/default.nix`

- [ ] **Step 1: Create the directory and file**

Run:

```bash
mkdir -p images/do-generic
```

- [ ] **Step 2: Write the module**

Write `images/do-generic/default.nix`:

```nix
# Generic DigitalOcean-bootable NixOS profile.
#
# Scope: hardware/boot/network only. No users, tooling, or roles — those come
# from other modules (e.g. users/o__ni, common/server.nix). Importing this
# module exposes `system.build.digitalOceanImage` (a qcow2 builder) and wires
# the runtime bits a droplet needs: virtio drivers, growpart on the root
# partition, and cloud-init for networking from DO metadata.
#
# Constraint: root filesystem must be ext4 (autoResize uses online ext4 resize).

{ modulesPath, lib, ... }:

{
  imports = [
    "${modulesPath}/virtualisation/digital-ocean-image.nix"
  ];

  boot = {
    loader.grub = {
      enable = true;
      device = "/dev/vda";
    };

    growPartition = true;

    initrd.availableKernelModules = [
      "virtio_pci"
      "virtio_scsi"
      "virtio_blk"
      "sd_mod"
    ];
  };

  fileSystems."/".autoResize = true;

  networking = {
    useDHCP = false;
    hostName = lib.mkDefault "";
  };

  services.cloud-init = {
    enable = true;
    network.enable = true;
    settings.datasource_list = [
      "DigitalOcean"
      "None"
    ];
  };
}
```

- [ ] **Step 3: Format**

Run:

```bash
nix develop -c nixfmt images/do-generic/default.nix
```

- [ ] **Step 4: Commit**

```bash
git add images/do-generic/default.nix
git commit -m "feat(images): add generic DigitalOcean image profile"
```

Note: this commit alone does not change `nix flake check` output because the module is not yet referenced by any `nixosConfigurations` attribute.

---

## Task 2: Wire `nixosConfigurations.do-generic` and `packages.do-image` into `flake.nix`

**Files:**
- Modify: `flake.nix`

- [ ] **Step 1: Read the current flake**

Open `flake.nix`. Locate (a) the block defining `nixosConfigurations` (around the existing `mokosh`, `veles`, `buyan`, `nixpi` entries) and (b) the `packages = forAllSystems (...)` block at the end.

- [ ] **Step 2: Add the `do-generic` nixosSystem**

Inside `outputs = { ... }: let ... in { ... }`, add this attribute next to the other `nixosConfigurations` entries (placement: after `buyan`, before the `homeConfigurations` block):

```nix
      # generic DigitalOcean image (any x86_64 droplet)
      nixosConfigurations."do-generic" = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = inputs;
        modules = [
          ./common/cache.nix
          ./common/server.nix
          ./users/o__ni
          ./images/do-generic
          { system.stateVersion = "26.05"; }
        ];
      };
```

- [ ] **Step 3: Expose the image as a flake package**

In the existing `packages = forAllSystems (system: let pkgs = nixpkgsFor.${system}; in { bulwark-webmail = pkgs.bulwark-webmail; })` block, change the inner attrset to also expose `do-image` only for `x86_64-linux`:

Replace the existing `packages = ...` block at the bottom of the file with:

```nix
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgsFor.${system};
        in
        {
          bulwark-webmail = pkgs.bulwark-webmail;
        }
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          do-image = self.nixosConfigurations."do-generic".config.system.build.digitalOceanImage;
        }
      );
```

Note: `self` must be in scope. Check the existing `outputs = { nixpkgs, nixpkgs-unstable, ... }@inputs: ...` line — `self` is *not* currently destructured. Update that line to include `self`:

```nix
  outputs =
    { self, nixpkgs, nixpkgs-unstable, ... }@inputs:
```

- [ ] **Step 4: Format**

```bash
nix develop -c nixfmt flake.nix
```

- [ ] **Step 5: Evaluate the flake**

Run:

```bash
make check
```

Expected: command exits 0. If it errors with `attribute 'digitalOceanImage' missing`, that means the upstream module name or attribute changed — re-check `<nixpkgs>/nixos/modules/virtualisation/digital-ocean-image.nix` in the locked nixpkgs and adjust.

If it errors with `attribute 'datasource_list' missing` under `services.cloud-init.settings`, the option name in the locked nixpkgs differs. Fall back to setting it via `services.cloud-init.config` raw YAML:

```nix
services.cloud-init = {
  enable = true;
  network.enable = true;
  config = ''
    datasource_list: [ DigitalOcean, None ]
  '';
};
```

Re-run `make check` after the fallback.

- [ ] **Step 6: Commit**

```bash
git add flake.nix
git commit -m "feat(flake): add do-generic nixosConfiguration and do-image package"
```

---

## Task 3: Build the image

**Files:** none modified — verification only.

- [ ] **Step 1: Build**

Run on an x86_64 Linux host (or via a remote builder from macOS):

```bash
nix build .#do-image
```

Expected: command exits 0, `result` symlink appears.

- [ ] **Step 2: Inspect the artifact**

```bash
ls -lh result/
file result/nixos.qcow2 || file result/*.qcow2 || ls result/
```

Expected: a `nixos.qcow2` (or similar) file present. Size should be in the hundreds-of-MB range (small generic NixOS + cloud-init + nix tooling).

If the artifact name differs (e.g. compressed as `.qcow2.gz`), note the actual name — it will be used in Task 4.

- [ ] **Step 3: No commit**

Build outputs are not committed. Move to Task 4.

---

## Task 4: QEMU smoke test

**Files:** none modified — verification only.

This step requires KVM. On macOS hosts, run the build + QEMU on a Linux box (or skip and jump to Task 6's DO smoke test).

- [ ] **Step 1: Boot the image**

Copy the image out of the read-only Nix store so QEMU can write to it:

```bash
cp -L result/nixos.qcow2 /tmp/do-test.qcow2
chmod u+w /tmp/do-test.qcow2

qemu-system-x86_64 \
  -m 1024 \
  -enable-kvm \
  -nographic \
  -drive file=/tmp/do-test.qcow2,format=qcow2,if=virtio \
  -nic user,hostfwd=tcp::2222-:22
```

(If the file is `nixos.qcow2.gz`, decompress first with `gunzip -k`.)

Expected: console output shows kernel boot, NixOS systemd reaches multi-user.target. cloud-init will log a warning that DO metadata is unreachable and fall through to the `None` datasource — this is intentional.

- [ ] **Step 2: SSH in**

From another terminal on the host:

```bash
ssh -p 2222 -o StrictHostKeyChecking=no o__ni@localhost
```

Expected: login succeeds using the SSH key baked from `users/o__ni`. (If no networking is available inside the guest because cloud-init didn't configure it, this step verifies QEMU user-mode networking only — to also reach the guest, the image needs an interface up. If sshd is unreachable in QEMU, that's a known limitation for the local smoke test; this is documented as such in the spec edge-cases section and is **not** a blocker. The authoritative smoke test is Task 6 on a real droplet.)

- [ ] **Step 3: Verify root resize on first boot**

Inside the VM (or via SSH if reachable):

```bash
df -h /
```

Expected: root filesystem size matches the qcow2 virtual size (qemu defaults the disk to the image's virtual size, so this verifies that growpart + autoResize at least did not break boot; the dramatic resize is on DO where the droplet disk is much larger).

- [ ] **Step 4: Shut down the VM**

Press `Ctrl-A X` (nographic QEMU exit) or `poweroff` from inside the guest.

- [ ] **Step 5: No commit**

Move to documentation.

---

## Task 5: Document the DO bootstrap flow in README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Locate the insertion point**

In `README.md`, find the `## Adding a New Machine` section (around line 158).

- [ ] **Step 2: Add a new subsection**

After the closing line of `## Adding a New Machine` (the bullet `4. Set system.stateVersion = "26.05"`), insert this new section. The literal content to paste is between the `````` markers below (do NOT paste the `````` markers themselves):

``````
## Bootstrapping a DigitalOcean Droplet

A generic DO-bootable qcow2 image is exposed as a flake package. The image
contains a minimal NixOS with SSH, the operator user, the binary cache, and
cloud-init for network configuration from DO metadata. It does **not** bake
in any machine's role set — apply the per-machine config after first boot.

```bash
# Build (x86_64 Linux host, or via remote builder from macOS)
nix build .#do-image

# Upload result/nixos.qcow2 to DigitalOcean → Images → Custom Images,
# then create a droplet from that custom image.

# SSH in as the operator user (cloud-init populates networking from DO metadata):
ssh o__ni@<droplet-ip>

# On the droplet: clone this flake, install secrets, switch to the machine config.
git clone <this-repo> ~/my-nix && cd ~/my-nix
make unlock
sudo make install-secrets
sudo hostnamectl set-hostname <machine>   # e.g. mokosh
sudo make switch
```

The image is generic — the same artifact can bootstrap any x86_64 NixOS
machine in this flake. The `make switch` step picks the machine config from
`$(hostname)`.
``````

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(readme): document DigitalOcean droplet bootstrap"
```

---

## Task 6: Stage mokosh cutover edits (branch-only)

**Files:**
- Modify: `machines/mokosh/default.nix`

> **Do not merge this task's commit to `main` until the droplet is up and verified.** This change breaks the on-prem mokosh because it removes the static IP block.

- [ ] **Step 1: Open the file**

Open `machines/mokosh/default.nix`. The relevant blocks are:

- the `let` binding `ip = (import ../../secrets).ip.mokosh;` (around line 11)
- the `imports = [ ... ../../hardware/vm.nix ... ]` block (around line 17)
- the `networking` block with `useDHCP`, `interfaces."${ifname}"`, `defaultGateway` (around lines 38–57)

- [ ] **Step 2: Replace `hardware/vm.nix` import with the DO image profile**

Change:

```nix
    ../../hardware/vm.nix
```

to:

```nix
    ../../images/do-generic
```

- [ ] **Step 3: Drop the static IP block and the `ip` binding**

Remove these lines from the `let` block:

```nix
  ip = (import ../../secrets).ip.mokosh;
```

Remove these lines from the `networking` block, keeping `hostName`, `nameservers`, and `firewall.enable`:

```nix
    useDHCP = false;

    interfaces."${ifname}" = {
      ipv4.addresses = [
        {
          address = ip.address;
          prefixLength = 24;
        }
      ];
    };

    defaultGateway = {
      address = ip.gateway;
      interface = ifname;
    };
```

The resulting `networking` block should be:

```nix
  networking = {
    hostName = hostname;
    nameservers = [ "1.1.1.1" ];
    firewall.enable = true;
  };
```

- [ ] **Step 4: Drop the `ifname` binding if no longer used**

After removing the `interfaces."${ifname}"` and `defaultGateway` blocks, `ifname` is still used by `roles.wireguardRouter.externalIf = ifname;`. Keep the `ifname` binding. **Do not remove it.**

Verify by grepping:

```bash
grep -n ifname machines/mokosh/default.nix
```

Expected: at least one remaining use under `roles.wireguardRouter.externalIf`.

- [ ] **Step 5: Drop `boot.loader.grub.device`**

The line:

```nix
  boot.loader.grub.device = "/dev/vda";
```

is now redundant — `images/do-generic` already sets `boot.loader.grub.device = "/dev/vda"`. Remove the mokosh-side line to avoid surprising overrides.

- [ ] **Step 6: Format**

```bash
nix develop -c nixfmt machines/mokosh/default.nix
```

- [ ] **Step 7: Evaluate**

```bash
make check
```

Expected: exits 0. Both `nixosConfigurations.mokosh` and `nixosConfigurations.do-generic` evaluate.

- [ ] **Step 8: Confirm the mokosh image builds too**

As a bonus verification that the mokosh-side import is benign:

```bash
nix build .#nixosConfigurations.mokosh.config.system.build.digitalOceanImage --no-link
```

Expected: build completes (it produces a mokosh-flavored DO image as a side effect of the shared module). This is not a deliverable — we are not promising a baked mokosh image — but the build succeeding proves the wiring is consistent.

- [ ] **Step 9: Commit**

```bash
git add machines/mokosh/default.nix
git commit -m "feat(mokosh): switch to DO image profile, drop static IP

Mokosh will receive its IP from DigitalOcean metadata via cloud-init.
DO NOT MERGE until the droplet is provisioned and verified."
```

---

## Task 7: Final verification

**Files:** none modified — verification only.

- [ ] **Step 1: Re-run flake check**

```bash
make check
```

Expected: exits 0.

- [ ] **Step 2: Re-run do-image build**

```bash
nix build .#do-image
```

Expected: exits 0, `result/` present.

- [ ] **Step 3: Confirm branch state**

```bash
git log --oneline main..HEAD
```

Expected: spec commit + 4 feature commits in order:
1. `docs: design for DigitalOcean image for mokosh`
2. `feat(images): add generic DigitalOcean image profile`
3. `feat(flake): add do-generic nixosConfiguration and do-image package`
4. `docs(readme): document DigitalOcean droplet bootstrap`
5. `feat(mokosh): switch to DO image profile, drop static IP`

- [ ] **Step 4: Branch handoff**

The branch `feat/mokosh-do-image` is now ready for the migration. **Do not open a PR / merge to `main` yet.** The mokosh commit (#5 above) will break the on-prem mokosh as soon as it is applied via `nixos-rebuild switch`.

Migration runbook (executed by the operator, not the implementer):

1. `nix build .#do-image` on a Linux host.
2. Upload `result/nixos.qcow2` to DO → Custom Images.
3. Create droplet from the custom image.
4. SSH in as `o__ni`. Confirm networking and shell work.
5. `git clone` this repo; check out `feat/mokosh-do-image`.
6. `make unlock && sudo make install-secrets`.
7. `sudo hostnamectl set-hostname mokosh`.
8. `sudo make switch`.
9. Verify representative services: `systemctl status nginx postfix dovecot vaultwarden`.
10. Update DNS to point at the droplet IP.
11. Once verified, merge `feat/mokosh-do-image` to `main` and decommission the old VPS.
