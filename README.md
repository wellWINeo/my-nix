# my-nix

Personal NixOS configuration repository for managing multiple machines and standalone home-manager configs using Nix Flakes (nixos-25.11).

## Machines

| Hostname | Hardware | Specs | Purpose |
|----------|----------|-------|---------|
| `mokosh` | VPS | 1 CPU, 2GB RAM | Main server — website, mail, VPN, vault, blog, RSS, calibre, backup |
| `veles` | VPS | 1 CPU, 1GB RAM (RU) | Xray relay, mtproxy, stream-forwarder to mokosh |
| `buyan` | VPS | 1 CPU, 1GB RAM (NL) | Xray server (entry point) |
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
│   │   └── rss/             #   miniflux + summarizer + backup
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
│   ├── coding-agents/       # Coding agent asset deployment (claude, opencode)
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

## Roles System

Roles are auto-discovered from the `roles/` directory. Machine configs import `../../roles` and enable only what they need:

```nix
imports = [ ../../roles ];

roles.vault.enable = true;
roles.blog = { enable = true; baseDomain = "example.com"; };
```

To add a new role, create a `.nix` file in `roles/` — no import registration needed.

## Adding a New Machine

1. Create `machines/<hostname>/default.nix` following the machine config pattern
2. Add to `flake.nix` under `nixosConfigurations` with appropriate system
3. Import `../../roles` and enable needed roles
4. Set `system.stateVersion = "25.11"`

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

## Adding a New Role

1. Create `roles/<name>.nix` (or `roles/<category>/<name>.nix`)
2. Define options under `options.roles.<name>` with `mkEnableOption`
3. Implement config under `config = mkIf cfg.enable`
4. The auto-discovery in `roles/default.nix` picks it up automatically
5. Enable in machine config: `roles.<name>.enable = true`
