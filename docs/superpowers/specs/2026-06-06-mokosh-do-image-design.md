# DigitalOcean image for mokosh — design

## Goal

Migrate `mokosh` (currently a generic VPS) onto a DigitalOcean droplet by
producing a DO-uploadable qcow2 NixOS image from this flake.

The image itself is **generic**: it boots a minimal NixOS with SSH, the user
account, the binary cache, and DO-aware networking. Mokosh's role set is
applied **after** the droplet is up, via the normal flake workflow
(`make unlock && make install-secrets && make switch`).

## Non-goals

- Automating first-boot `nixos-rebuild` on the droplet.
- Baking real `/etc/nixos/secrets/*` material into the image.
- Provisioning DO itself (creating the custom image entry, droplet, DNS) via
  Terraform/`doctl`. Done manually for now.
- Changing the on-prem mokosh's static-IP networking until cutover.

## Approach

A generic, machine-agnostic image profile under `images/do-generic/`,
consumed by a new `nixosConfigurations.do-generic` whose
`system.build.digitalOceanImage` is exposed as
`packages.x86_64-linux.do-image`.

Trade-off summary (recorded for future reference):

- **Generic image + post-deploy `make switch` (chosen).** Image stays small
  and reusable; never goes stale w.r.t. flake content; one artifact can
  bootstrap any machine. Two-phase deploy is acceptable because (a) this is
  a deliberate migration, not autoscaling, and (b) the existing S3 binary
  cache makes the post-deploy switch fast.
- **Baked mokosh image (rejected).** Faster first boot, but image must be
  rebuilt on every config change to remain a valid DR artifact, and the
  closure is large.

Upstream `nixos/modules/virtualisation/digital-ocean-image.nix` is the
canonical builder and is used directly. `nixos-generators` is not
introduced.

`nixos/modules/virtualisation/digital-ocean-config.nix` (the full DO runtime
integration: cloud-init for SSH keys, hostname, network, droplet metadata) is
**not** imported. We use cloud-init only for networking; SSH keys and tooling
come from `users/o__ni`.

## Components

### `images/do-generic/default.nix` (new)

DO image hardware + runtime profile. Scope is hardware/boot/network only;
no users, no tooling, no roles.

Responsibilities:

- Import `<nixpkgs/nixos/modules/virtualisation/digital-ocean-image.nix>` to
  expose `system.build.digitalOceanImage`.
- `boot.loader.grub.enable = true;` with device `/dev/vda` (DO uses
  virtio-blk).
- `boot.growPartition = true;` and `fileSystems."/".autoResize = true;` so
  the root partition + ext4 FS expand to the droplet's disk on first boot.
- `boot.initrd.availableKernelModules` for virtio: `virtio_pci`,
  `virtio_scsi`, `virtio_blk`, `sd_mod`.
- `services.cloud-init.enable = true;` with networking enabled
  (`services.cloud-init.network.enable = true;` on current nixpkgs).
- Configure cloud-init's `datasource_list` to `[DigitalOcean, None]` via the
  NixOS module's settings/config option (exact attribute name to be confirmed
  against `nixos-25.11` at implementation time). The `None` fallback keeps
  boot from hanging when metadata is unreachable, e.g. local QEMU smoke
  tests.
- `networking.useDHCP = false;` — cloud-init renders the network config from
  DO metadata; we do not want a parallel DHCP path.
- `networking.hostName = "";` — empty hostname so cloud-init sets it from
  DO metadata at first boot.

Does **not** set: any user, any role, any SSH config beyond defaults, any
firewall rules beyond the base server module.

### `nixosConfigurations.do-generic` in `flake.nix` (new)

Small `nixpkgs.lib.nixosSystem` value:

```nix
nixosConfigurations.do-generic = nixpkgs.lib.nixosSystem {
  system = "x86_64-linux";
  specialArgs = inputs;
  modules = [
    ./common/cache.nix
    ./common/server.nix
    ./users/o__ni
    ./images/do-generic
    { system.stateVersion = "25.11"; }
  ];
};
```

No mokosh role imports. No `machines/mokosh` import. Reuses the existing
operator user (which already provides `git`, `gnupg`, `gnumake`, `neovim`,
hashed password, and authorized SSH key) and the existing S3 binary cache
config.

### `packages.x86_64-linux.do-image` in `flake.nix` (new)

```nix
do-image = self.nixosConfigurations.do-generic.config.system.build.digitalOceanImage;
```

Built locally with `nix build .#do-image`. Output: a gzipped qcow2 under
`result/`.

### `users/o__ni` (unchanged)

Already provides everything we need for first-SSH bootstrap:

- `users.users.o__ni` with `hashedPassword` and `openssh.authorizedKeys.keys`
  drawn from `secrets`.
- Packages: `git`, `gnupg`, `gnumake`, `neovim`, `htop`, `neofetch`.
- `nix.settings.experimental-features = [ "flakes" "nix-command" ];`

No edits required.

### `machines/mokosh/default.nix` (changed at cutover, not as part of image work)

When migration happens, the static-IP block is removed and replaced with
reliance on cloud-init networking. Specifically:

- Drop `networking.useDHCP`, `networking.interfaces."${ifname}"`, and
  `networking.defaultGateway` (those came from `secrets.ip.mokosh`).
- Keep `networking.hostName = "mokosh";` — the flake wins over cloud-init's
  metadata-derived hostname after `make switch`.
- Replace the `hardware/vm.nix` import (Hyper-V guest) with `./images/do-generic`.
  The DO image profile's runtime bits — virtio modules, growpart, cloud-init
  networking — are exactly what we want on the running droplet too. The
  `digital-ocean-image.nix` upstream module only adds the
  `system.build.digitalOceanImage` derivation; it has no other runtime
  side effects, so importing it into mokosh's running config is harmless
  (and convenient: rebuilding mokosh's own image becomes trivial).

This change is staged on a branch and only merged once the droplet is up,
so the on-prem mokosh keeps working in the meantime.

## Data flow

```
flake.nix
  └── nixosConfigurations.do-generic
        ├── common/cache.nix         (S3 substituter + trusted key)
        ├── common/server.nix        (sshd, base nginx defaults)
        ├── users/o__ni              (operator: pubkey, gpg, make, git)
        └── images/do-generic        (DO image builder, cloud-init net, growpart)
              ↓
        config.system.build.digitalOceanImage
              ↓
        result/nixos.qcow2.gz   →   upload to DO Custom Images
                                →   create droplet
                                →   cloud-init pulls IP/gateway/DNS/hostname
                                →   sshd up, o__ni authorized
                                →   ssh in, clone repo, install secrets, make switch
```

## Migration / cutover for mokosh

Performed once the image work lands:

1. Build: `nix build .#do-image` on a local x86_64 Linux host (or via remote
   builder from macOS).
2. Upload `result/nixos.qcow2.gz` to DO → Images → Custom Images.
3. Create a droplet from the custom image in the desired region/size.
4. SSH: `ssh o__ni@<droplet-ip>`.
5. Bootstrap:
   - `git clone <repo> /home/o__ni/my-nix && cd /home/o__ni/my-nix`
   - Check out the branch with the mokosh static-IP removal.
   - `make unlock` (interactive GPG passphrase).
   - `sudo make install-secrets` (writes `/etc/nixos/secrets/*`).
   - `sudo make switch` — picks `nixosConfigurations.mokosh` via
     `$(hostname)`.
6. Roles come up. Verify mail/vault/blog/etc. Update DNS to point at the
   droplet IP.
7. Decommission old VPS once verification passes.

## Edge cases

- **Local QEMU test boot.** `datasource_list = [ "DigitalOcean" "None" ]`
  prevents cloud-init from blocking on metadata when the image is booted
  outside DO. Network simply doesn't come up; SSH-via-host-port-forward
  works via the user network in QEMU using DHCP from QEMU's user-mode net —
  noted that this requires a small override module if needed for tests; not
  blocking for the initial implementation.
- **Root FS resize.** Only ext4 is supported by `autoResize`. Mokosh uses
  ext4 (`machines/mokosh/default.nix:30`). Documented as a constraint of
  `images/do-generic`.
- **sshd before network.** Standard NixOS ordering: sshd's socket activation
  binds after `network-online.target`. No special wiring required; cloud-init
  brings up `ens3` (or whatever DO assigns) before that target completes.
- **Stale image.** The image's only flake dependencies are the operator
  pubkey, the cache pubkey, the channel pin, and the cloud-init / kernel
  packages. A rebuild is only needed if any of those change materially.
- **Secrets in image.** The image contains `secrets.hashedPassword` and
  `secrets.sshKey` (public). Both already ship in every NixOS closure built
  from this flake; no new exposure. No `/etc/nixos/secrets/*` content is
  embedded.
- **Hostname.** Empty `networking.hostName` in the image lets cloud-init set
  it from droplet metadata. After `make switch` to mokosh, the flake sets
  `mokosh` explicitly and wins.

## Testing

- `nix flake check` after wiring up the new config.
- `nix build .#do-image` produces a non-empty qcow2.
- QEMU smoke test:
  ```
  qemu-system-x86_64 \
    -m 1024 -enable-kvm \
    -drive file=result/nixos.qcow2,format=qcow2 \
    -nic user,hostfwd=tcp::2222-:22
  ssh -p 2222 o__ni@localhost
  ```
  Verify: boot completes, root FS expands, sshd answers, login works.
- DO smoke test: upload to DO, create a $4–6/mo droplet, confirm cloud-init
  populates networking, SSH in as `o__ni`, run `make switch` to apply
  mokosh's role set, verify a couple of representative services
  (`systemctl status nginx postfix dovecot vaultwarden`).

## Documentation

- New short section in `README.md` under "Adding a New Machine" titled
  "Bootstrapping a DigitalOcean droplet" with the cutover steps.
- Header comment in `images/do-generic/default.nix` describing scope (DO
  hardware + cloud-init networking only; tooling and user belong elsewhere).

## Out-of-scope follow-ups

- Generic image variants for other providers (Hetzner, Vultr) under
  `images/`.
- Automating image upload to DO via `doctl` in CI.
- A first-boot oneshot that auto-clones the flake and runs `nixos-rebuild
  switch --flake .#$(hostname)` (the "hybrid" approach considered during
  brainstorming).
