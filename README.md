# my-nix

Personal NixOS configuration repository for managing multiple machines using Nix Flakes.

## Machines

| Hostname | Hardware | Specs | Purpose |
|----------|----------|-------|---------|
| `mokosh` | VPS | 1 CPU, 2GB RAM | Main server - website, mail, VPN, vault, blog |
| `veles` | VPS | 2 CPU, 4GB RAM | Secondary server |
| `nixpi` | Raspberry Pi 4 | 2GB RAM | Home server - media, NAS, DNS, DHCP |

## Directory Structure

```
├── flake.nix           # Main flake defining all NixOS configurations
├── flake.lock          # Locked dependency versions
├── Makefile            # Common operations (unlock secrets, deploy)
├── machines/           # Per-machine configuration
│   ├── mokosh/         # VPS configuration
│   ├── veles/          # Secondary VPS
│   └── nixpi/          # Raspberry Pi 4
├── roles/              # Reusable service modules (NixOS modules)
│   ├── blog.nix        # Writefreely blog
│   ├── vault.nix       # Vaultwarden password manager
│   ├── media.nix       # Media server (Jellyfin/Plex)
│   └── ...             # Other services
├── common/             # Shared configurations
│   ├── server.nix      # Base server setup (SSH, GPG)
│   ├── hardened.nix    # Security hardening (fail2ban)
│   └── ...             # Other common configs
├── hardware/           # Hardware-specific configs
│   ├── vm.nix          # Virtual machine setup
│   └── rpi4.nix        # Raspberry Pi 4 setup
├── users/              # User configurations
│   └── o__ni/          # Main user setup
├── secrets/            # Encrypted secrets (gitignored)
│   ├── secrets.json.gpg    # Encrypted JSON secrets
│   └── locked.tar.gpg      # Encrypted file secrets
└── assets/             # Static assets for services
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

# Check flake validity
make check

# Deploy to current machine
make switch
```

## Secrets Management

Secrets are stored in two encrypted locations:

1. **`secrets/secrets.json.gpg`** - Simple key-value secrets (passwords, tokens, SSH keys)
   - Decrypted to `secrets/secrets.json`
   - Accessed via `import ../../secrets` in Nix files

2. **`secrets/locked.tar.gpg`** - File-based secrets (certificates, environment files)
   - Decrypted to `secrets/unlocked/`
   - Installed via `make install-secrets`

```bash
# Decrypt all secrets
make unlock

# Re-encrypt secrets after changes
make lock

# Install unlocked secrets to /etc/nixos/secrets
sudo make install-secrets
```

## Makefile Commands

| Command | Description |
|---------|-------------|
| `make unlock` | Decrypt all secrets (JSON + files) |
| `make unlock-json` | Decrypt only secrets.json |
| `make unlock-files` | Decrypt only locked.tar |
| `make lock` | Re-encrypt all secrets |
| `make install-secrets` | Copy secrets to /etc/nixos/secrets based on spec.txt |
| `make check` | Run `nix flake check` |
| `make switch` | Deploy configuration to current machine |

## Adding a New Machine

1. Create `machines/<hostname>/default.nix`
2. Add configuration to `flake.nix` under `nixosConfigurations`
3. Import required roles from `roles/`
4. Set `system.stateVersion`

## Adding a New Role

1. Create `roles/<name>.nix`
2. Define options under `options.roles.<name>`
3. Implement config under `config = mkIf cfg.enable`
4. Import and enable in machine config
