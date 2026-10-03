# my-nix

Personal NixOS configuration repository for managing multiple machines and standalone home-manager configs using Nix Flakes (nixos-25.11).

## Machines

| Hostname | Hardware | Specs | Purpose |
|----------|----------|-------|---------|
| `mokosh` | VPS | 1 CPU, 2GB RAM | Main server — website, mail, VPN, vault, blog, RSS, calibre, backup |
| `veles` | VPS | 1 CPU, 1GB RAM (RU) | Xray relay, mtproxy, stream-forwarder to mokosh |
| `buyan` | VPS | 1 CPU, 1GB RAM (NL) | Xray server (entry point) |
| `stribog` | VPS | 1 CPU, 1GB RAM (RU, Timeweb) | Xray server (entry point, pilot for nixos-anywhere provisioning) |
| `nixpi` | Raspberry Pi 4 | Home server | Media, NAS, DNS, DHCP, photos, torrent |
| macOS | MacBook Pro | — | Standalone home-manager configs (alacritty, neovim, tmux, coding agents) |

## Directory Structure

```
├── flake.nix                # Main flake — all NixOS + home-manager configs
├── flake.lock               # Locked dependency versions
├── Makefile                 # Common operations (unlock, deploy, check)
├── machines/                # Per-machine NixOS configs
│   ├── mokosh/              # Main VPS
│   ├── veles/               # Russian relay VPS
│   ├── buyan/               # Netherlands entry VPS
│   ├── stribog/             # Timeweb entry VPS
│   └── nixpi/               # Raspberry Pi 4
├── roles/                   # Reusable service modules (auto-discovered)
│   ├── default.nix          # Auto-discovers all roles recursively
│   ├── blog.nix             # Writefreely blog
│   ├── vault.nix            # Vaultwarden password manager
│   ├── media.nix            # Media server
│   ├── backup.nix           # Backup (restic to S3)
│   ├── letsencrypt.nix      # ACME certificate management
│   ├── photos.nix           # Photo management (Immich)
│   ├── share.nix            # File sharing (SMB/Timemachine)
│   ├── torrent.nix          # Torrent client
│   ├── personal-website.nix # Static personal website
│   ├── communication/       # Mail server
│   ├── network/             # Proxy/VPN roles
│   │   ├── shadowsocks/     #   client + server
│   │   ├── sing-box/        #   client + server
│   │   ├── wireguard/       #   client + router
│   │   ├── xray/            #   server + relay + client + transports
│   │   ├── mtproxy.nix      #   MTProxy
│   │   ├── sni-router.nix   #   SNI-based routing
│   │   └── stream-forwarder.nix
│   ├── reading/             # Reading apps
│   │   ├── calibre.nix
│   │   ├── readeck.nix
│   │   └── rss/             #   miniflux + RSSHub + summarizer + backup
│   └── router/              # Home router roles
│       ├── dhcp.nix
│       ├── dns.nix
│       └── nginx.nix        #   home nginx with PAC proxy
├── common/                  # Shared configs and utilities
│   ├── server.nix           # Base server setup (SSH, GPG, nginx defaults)
│   ├── hardened.nix         # Security hardening (fail2ban)
│   ├── filter-proxy-users.nix # Filter singBox users by hostname
│   ├── zeroconf.nix         # Avahi/mDNS
│   ├── btrfs-balance.nix    # Periodic btrfs balance
│   ├── define-media-user.nix # Media user/group
│   ├── sqlite-backup.nix    # SQLite backup utility
│   └── shadowsocks.nix      # Shadowsocks common config
├── hardware/                # Hardware-specific configs
│   ├── vm.nix               # Virtual machine setup
│   └── rpi4.nix             # Raspberry Pi 4 setup
├── home/                    # Home-manager modules (macOS)
│   ├── default.nix          # Base home config
│   ├── themes/              # Global theme system (one-dark, one-half-light)
│   ├── software/            # App configs (alacritty, neovim)
│   ├── coding-agents/       # Coding agent asset deployment (claude, shared .agents for opencode/Codex)
│   └── tmux.nix             # Tmux config
├── users/                   # NixOS user definitions
│   └── o__ni/
├── overlays/                # Global nixpkgs overlays
│   └── default.nix
├── secrets/                 # Encrypted secrets (gitignored)
│   ├── secrets.json.gpg     # Encrypted JSON secrets
│   ├── locked.tar.gpg       # Encrypted file secrets
│   └── secrets.dummy.json   # Placeholder secrets for CI/agents
├── assets/                  # Static assets for services
└── docs/                    # Documentation and plans
```

### Coding-agent assets

- Shared opencode/Codex instructions: `~/.agents/AGENTS.md`
- Shared opencode/Codex skills: `~/.agents/skills/`
- Claude instructions and skills: `~/.claude/`
- Harness-specific agent definitions remain under their native directories.

This repository does not currently manage custom command files. OpenCode and
Codex use different custom-agent formats, so agent definitions are not moved to
a shared `.agents/agents/` directory.

## Prerequisites

- Nix with flakes enabled
- GPG for secrets management

## Quick Start

```bash
# Enter development shell (provides nixfmt, nixd)
nix develop

# Unlock secrets (requires GPG key)
make unlock

# For CI/agents without GPG — use dummy secrets
make setup-dummy-secrets

# Check flake validity
make check

# Deploy to current machine (NixOS)
make switch

# Apply home-manager config (macOS)
make apply:home
```

## Operations

- [Manage Cloudflare DNS declaratively](docs/dns.md)

## Secrets Management

Secrets are stored in two encrypted locations:

1. **`secrets/secrets.json.gpg`** - Key-value secrets (passwords, tokens, IPs, proxy users)
   - Decrypted to `secrets/secrets.json`
   - Accessed via `import ../../secrets` in Nix files

2. **`secrets/locked.tar.gpg`** - File-based secrets (certificates, private keys, env files)
   - Decrypted to `secrets/unlocked/`
   - Installed via `make install-secrets`

```bash
make unlock              # Decrypt all secrets (JSON + files)
make lock                # Re-encrypt secrets after changes
make install-secrets     # Install unlocked secrets to /etc/nixos/secrets
make setup-dummy-secrets # Copy placeholder secrets (for CI/agents)
```

## Makefile Commands

| Command | Description |
|---------|-------------|
| `make unlock` | Decrypt all secrets (JSON + files) |
| `make unlock-json` | Decrypt only secrets.json |
| `make unlock-files` | Decrypt only locked.tar |
| `make lock` | Re-encrypt all secrets |
| `make setup-dummy-secrets` | Copy placeholder secrets for CI/agents |
| `make install-secrets` | Copy secrets to /etc/nixos/secrets based on spec.txt |
| `make check` | Run `nix flake check` |
| `make switch` | Deploy configuration to current NixOS machine |
| `make apply:home` | Apply home-manager config for current user@hostname |
| `make apply:home:ATTR` | Apply specific home-manager config by attribute name |
| `make fmt` | Format all Nix files |
| `make provision HOST=H IP=IP` | Install a proxy VPS from a NixOS live ISO (see below) |

## Roles System

Roles are auto-discovered from the `roles/` directory. Machine configs import `../../roles` and enable only what they need:

```nix
imports = [ ../../roles ];

roles.vault.enable = true;
roles.blog = { enable = true; baseDomain = "example.com"; };
```

To add a new role, create a `.nix` file in `roles/` — no import registration needed.

RSSHub is enabled on `mokosh` as `roles.rss.hub.enable`. It listens only on
`127.0.0.1:1200` for Miniflux and is not exposed through Nginx, DNS, or the
firewall. The initial browser-free route is
`http://127.0.0.1:1200/anthropic/research`.

Readeck is enabled on `mokosh` as `roles.readeck` and is available at
`https://readlater.uspenskiy.tech`. It listens only on `127.0.0.1:8000` behind
Nginx, uses SQLite under `/var/lib/readeck`, and is included in the existing
encrypted backup flow.

`roles.vpn` runs Headscale and Headplane on `mokosh` at
`https://headscale.uspenskiy.tech`; the Headplane UI is at `/admin/` and is
protected by HTTP Basic Auth plus a Headscale API key. The embedded DERP/STUN
relay is self-hosted on mokosh. `nixpi` runs Tailscale in parallel with its
existing WireGuard client; WireGuard remains the active fallback until a
separately approved retirement change.

## Adding a New Machine

1. Create `machines/<hostname>/default.nix` following the machine config pattern
2. Add to `flake.nix` under `nixosConfigurations` with appropriate system
3. Import `../../roles` and enable needed roles
4. Set `system.stateVersion = "26.05"`

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

## Provisioning a proxy VPS from a NixOS live ISO

New proxy VPSes are installed from a remotely accessible NixOS live ISO with
`provision/install.sh`, a guarded wrapper around `nixos-anywhere`. **The
target disk is destroyed.** The pilot host is `stribog`; `buyan` and `veles`
share the same workflow but have not been run against a real machine.

### Prerequisites

- A NixOS live ISO booted on the VPS with network up. On the ISO console:
  `passwd nixos` (short-lived SSH password for the installer).
- A controller with Nix (flakes) and GPG.
- Locally decrypted secrets: `make unlock` — only if `secrets/secrets.json`
  and `secrets/unlocked/` are not already unlocked.
- The ISO's ED25519 SSH host-key fingerprint, read from the provider console
  (out-of-band, not from the network).

### Run it

```bash
make provision HOST=stribog IP=<ISO-IP>
```

`HOST` is one of `buyan`, `veles`, `stribog`; `IP` is the live ISO's IPv4
address.

### What is checked before anything destructive

In order, the wrapper refuses to continue unless all of these pass:

1. **Local preflight** — `secrets/secrets.json` is present and JSON-shaped,
   `secrets/unlocked/spec.txt` exists, every required unlocked file is present
   (`xray-reality-private-key` and `tailscale-auth-key` on buyan/stribog;
   veles also needs `hysteria-veles-key` and `hysteria-veles-cert`) with a
   spec entry for the host or `*`, the hostname filter leaves a non-empty
   Xray user list, and the target disk evaluates from the flake.
2. **ISO trust gate** — the ISO's scanned ED25519 fingerprint must exactly
   match the value typed from the provider console; the scanned key is then
   pinned for the wrapper's own SSH connections.
3. **Live-ISO hardware preflight** — BIOS boot (UEFI is refused), the target
   disk exists as a whole disk, and it is big enough (16 GiB for buyan,
   8 GiB for veles/stribog; both leave room for the 2 GiB swapfile). The
   disk's path, size, and partition table are printed.
4. **Typed confirmation** — the hostname and the disk path must be retyped
   exactly. After this, every byte on that disk is destroyed.

### Two-phase install

The wrapper runs `nixos-anywhere` in two phases with one temporary installer
key (bootstrapped to root on the ISO via the `nixos` password):

- **Phase A** (`--phases disko`): partition and format the disk, verify
  `/mnt`, then create a 2 GiB `/.swapfile` on the mounted target so the 1 GB
  VPS can build its closure remotely.
- **Phase B** (`--phases install,reboot --build-on remote`): install the full
  configuration with the host's staged secrets (`--extra-files`), then reboot.

A failed phase never retries Disko on its own. If Phase A fails, the disk may
be partially partitioned — inspect the still-running live ISO first (provider
console or SSH: `lsblk`, `mount`, `journalctl`, install logs) before doing
anything else.

### Recovery: --resume-install

If Disko completed but the install phase failed, resume **without
repartitioning** (direct invocation, not via make):

```bash
HOST=<host> IP=<ip> nix develop .#provision -c ./provision/install.sh --resume-install
```

Resume repeats the fingerprint gate and the installer-key bootstrap (you type
the `nixos` password again), then requires the live ISO to still be booted
with the target root mounted at `/mnt` (remount it from the provider console
if needed, e.g. `mount /dev/disk/by-label/NIXROOT /mnt`). If ISO SSH is lost,
reach the machine through the provider console first.

### After install

The installed system has password SSH login disabled; log in as the operator:

```bash
ssh o__ni@<ip>
```

Expect **two SSH host-key transitions**: the fresh ISO has its own new host
key (the fingerprint you confirmed from the console), and the installed
system generates another new key on first boot. On the first post-install
login, verify the new fingerprint in the provider console before accepting
it — do not blindly delete the old `known_hosts` entry. The wrapper's
post-reboot SSH check is informational only.

### Honest limitations

- `nixos-anywhere` itself disables SSH host-key verification internally
  (`StrictHostKeyChecking=no`). The wrapper verifies the ISO fingerprint
  out-of-band once, before any destructive action, but cannot enforce
  per-connection checking inside nixos-anywhere.
- Decrypted secrets are already included in `path:.` flake snapshots and end
  up in the remote Nix store. This installer does not change that model.
- `buyan` and `veles` are installable by config but have **not** been
  deployed or runtime-tested this way — the pilot is `stribog` only.
- A real proxy smoke test on `stribog` also needs at least one `singBoxUser`
  whose `hosts` includes `stribog`. The wrapper refuses to install a host
  whose filtered user list is empty, but an installed Xray with zero real
  users is still not a working proxy.

## Adding a New Role

1. Create `roles/<name>.nix` (or `roles/<category>/<name>.nix`)
2. Define options under `options.roles.<name>` with `mkEnableOption`
3. Implement config under `config = mkIf cfg.enable`
4. The auto-discovery in `roles/default.nix` picks it up automatically
5. Enable in machine config: `roles.<name>.enable = true`
