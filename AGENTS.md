# AGENTS.md

Guide for AI coding agents working in this NixOS configuration repository.

## Project Overview

This is a NixOS configuration repository using Flakes (nixos-25.11 channel) to manage multiple machines and standalone home-manager configs:

- **mokosh**: Main VPS (1 CPU, 2GB RAM) — website, mail, VPN, vault, blog, RSS, calibre, backup
- **veles**: VPS (1 CPU, 1GB RAM, Russia) — xray relay, mtproxy, stream-forwarder to mokosh
- **buyan**: VPS (1 CPU, 1GB RAM, Netherlands) — xray server (entry point)
- **nixpi**: Raspberry Pi 4 (home server) — media, NAS, DNS, DHCP, photos, torrent
- **Home Manager** (macOS): Standalone configs for `o__ni@Stepans-MacBook-Pro` and `o__ni@DodoBook.local`

## Build/Lint/Test Commands

```bash
# Check flake validity (syntax, eval)
# Requires secrets/secrets.json — if not unlocked, use the dummy file first:
make setup-dummy-secrets  # copies secrets/secrets.dummy.json → secrets/secrets.json
make check
# Or directly:
nix flake check 'path:.' --all-systems

# Format all Nix files
nixfmt .

# Format specific file
nixfmt path/to/file.nix

# Enter dev shell (provides nixfmt, nixd)
nix develop

# Deploy to current machine (NixOS)
make switch

# Build without switching (dry run)
nixos-rebuild build --flake "path:.#$(hostname)"

# Apply home-manager config for current host (macOS)
make apply:home

# Apply home-manager config by exact attribute name (macOS)
make apply:home:o__ni@Stepans-MacBook-Pro

# Build home-manager config (macOS)
nix build 'path:.#homeConfigurations."o__ni@Stepans-MacBook-Pro".activationPackage'
```

Note: There are no automated tests. Validation is via `nix flake check` and manual deployment testing.

## Flake Inputs

| Input | Purpose |
|-------|---------|
| `nixpkgs` | nixos-25.11 stable |
| `nixpkgs-unstable` | Used for select packages (e.g. `telemt` on veles) |
| `nixos-hardware` | Hardware-specific tweaks (RPi4) |
| `home-manager` | User environment management (release-25.11) |
| `miniflux-summarizer` | RSS feed summarizer package (mokosh overlay) |
| `agent-skills` | Home-manager module for coding agent config deployment |

## Code Style Guidelines

### Formatting

- Use `nixfmt-rfc-style` for all Nix files
- Run `nixfmt .` before committing

### Imports and Module Structure

```nix
# Standard module pattern
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.roles.<name>;
in
{
  options.roles.<name> = {
    enable = mkEnableOption "Description";

    someOption = mkOption {
      type = types.str;
      description = "What this does";
    };
  };

  config = mkIf cfg.enable {
    # Implementation
  };
}
```

### Naming Conventions

- **Roles**: `roles.<feature-name>` (e.g., `roles.blog`, `roles.vault`)
- **Options**: camelCase (e.g., `baseDomain`, `enableWeb`)
- **Variables**: camelCase for local vars
- **Hostnames**: lowercase (e.g., `mokosh`, `nixpi`)

### Roles Auto-Import Pattern

Roles are auto-discovered via `roles/default.nix`, which recursively collects all `.nix` files and directories containing `default.nix`. Machine configs import the entire `roles/` directory — **do not import individual role files**.

```nix
imports = [
  ../../common/hardened.nix
  ../../common/server.nix
  ../../hardware/vm.nix
  ../../roles                  # imports ALL roles via auto-discovery
];
```

Then enable only the roles you need:

```nix
roles.vault.enable = true;
roles.blog.enable = true;
```

### Roles with Sub-Modules

Complex roles are organized into subdirectories under `roles/`:

| Directory | Contents |
|-----------|----------|
| `roles/communication/` | `mail.nix` |
| `roles/network/` | `shadowsocks/` (client + server), `sing-box/` (client + server), `wireguard/` (client + router), `xray/` (server + relay + client + transports), `mtproxy.nix`, `sni-router.nix`, `stream-forwarder.nix` |
| `roles/reading/` | `calibre.nix`, `rss/` (miniflux + summarizer + backup) |
| `roles/router/` | `dhcp.nix`, `dns.nix`, `nginx.nix` (home nginx with PAC proxy) |

Each subdirectory is auto-discovered if it contains a `default.nix`, or individual `.nix` files are picked up directly.

### Machine Config Pattern

All machine configs follow this structure:

```nix
{ lib, ... }:

let
  hostname = "example";
  ifname = "ens3";
  ip = (import ../../secrets).ip.example;
  secrets = import ../../secrets;
in
{
  imports = [
    ../../common/hardened.nix
    ../../common/server.nix
    ../../hardware/vm.nix
    ../../roles
  ];

  # boot, filesystems, networking...

  ###
  # Roles
  ###
  roles.hardened.enable = true;
  roles.someRole = { enable = true; /* options */ };

  system.stateVersion = "25.11";
}
```

### Secrets Access

```nix
# At top of file that needs secrets
let
  secrets = import ../../secrets;
in
{
  someConfig.password = secrets.somePassword;
}
```

### Filtering Proxy Users by Host

Use `common/filter-proxy-users.nix` to filter `secrets.singBoxUsers` for a specific hostname:

```nix
let
  filterProxyUsersForHost = import ../../common/filter-proxy-users.nix { inherit lib; };
  users = filterProxyUsersForHost hostname secrets.singBoxUsers;
in
```

### Nginx Virtual Hosts Pattern

```nix
services.nginx.virtualHosts.${hostname} = {
  forceSSL = true;
  enableACME = false;
  sslCertificate = "/var/lib/acme/${cfg.baseDomain}/fullchain.pem";
  sslCertificateKey = "/var/lib/acme/${cfg.baseDomain}/key.pem";

  locations."/" = {
    proxyPass = "http://localhost:${toString port}";
    recommendedProxySettings = true;
  };
};
```

### Overlays

Global overlays live in `overlays/default.nix`. Per-machine overlays (e.g., `miniflux-summarizer` on mokosh, `telemt` on veles) are added inline in `flake.nix` within the machine's `modules` list.

### Home Manager Config Pattern

Home-manager configs (macOS) use the `agent-skills` input and local modules:

```nix
homeConfigurations."o__ni@Stepans-MacBook-Pro" = inputs.home-manager.lib.homeManagerConfiguration {
  pkgs = nixpkgsFor.aarch64-darwin;
  extraSpecialArgs = { inherit inputs; };
  modules = [
    inputs.agent-skills.homeManagerModules.default
    ./home
    {
      software.alacritty.enable = true;
      theme.name = "one-dark";
      software.neovim.enable = true;
      codingAgents.claude.enable = true;
      codingAgents.opencode.enable = true;
    }
  ];
};
```

Home-manager option namespaces:
- `theme.name` — global theme selector (`one-dark`, `one-half-light`)
- `theme.colors` — resolved per-app color maps (read-only)
- `software.<app>.enable` — enable app config (alacritty, neovim)
- `codingAgents.<tool>.enable` — deploy coding agent assets (claude, opencode)

## Directory Purposes

| Directory | Purpose |
|-----------|---------|
| `machines/` | Per-machine NixOS configurations (`buyan/`, `mokosh/`, `nixpi/`, `veles/`) |
| `roles/` | Reusable service modules — auto-discovered via `default.nix` |
| `roles/communication/` | Mail server role |
| `roles/network/` | Proxy/VPN roles (shadowsocks, sing-box, wireguard, xray, mtproxy) |
| `roles/reading/` | Reading roles (calibre, rss/miniflux) |
| `roles/router/` | Home router roles (dhcp, dns, nginx with PAC) |
| `common/` | Shared configs, utilities, and reusable modules |
| `hardware/` | Hardware-specific configs (`vm.nix`, `rpi4.nix`) |
| `users/` | User account definitions |
| `secrets/` | Encrypted secrets (gitignored) |
| `home/` | Home-manager modules (themes, software, coding-agents, tmux) |
| `overlays/` | Global nixpkgs overlays |
| `assets/` | Static files for services |
| `docs/` | Documentation, plans |

## Common Directory Utilities

| File | Purpose |
|------|---------|
| `server.nix` | Base server setup (GPG agent, nginx defaults, SSH) |
| `hardened.nix` | Security hardening (fail2ban with nginx + ssh jails) |
| `filter-proxy-users.nix` | Filter `singBoxUsers` by hostname — used by proxy roles |
| `zeroconf.nix` | Avahi/mDNS role (nixpi) |
| `btrfs-balance.nix` | Periodic btrfs balance timer/service |
| `define-media-user.nix` | Media user/group definition |
| `sqlite-backup.nix` | SQLite backup utility |
| `shadowsocks.nix` | Shadowsocks common config |
| `backup-gpg-public.asc` | GPG public key for backups |

## Secrets

**Location**: `secrets/` directory (gitignored)

| File | Contents |
|------|----------|
| `secrets.json.gpg` | Key-value secrets (passwords, tokens, IPs, proxy users) |
| `locked.tar.gpg` | File-based secrets (certs, env files, private keys) |

**Commands**:
```bash
make unlock              # Decrypt all secrets (requires GPG key)
make lock                # Re-encrypt secrets
make install-secrets     # Copy to /etc/nixos/secrets/ based on spec.txt
make setup-dummy-secrets # Copy secrets.dummy.json → secrets.json (no GPG needed)
```

**Working without real secrets (agents/CI)**: If `secrets.json` is not decrypted (no GPG
access), run `make setup-dummy-secrets` before `make check`. This uses
`secrets/secrets.dummy.json` — a committed file with fake-but-valid placeholder values.

**Access pattern**:
```nix
secrets = import ../../secrets;
# secrets is a JSON attrset with all secrets
```

**Key secret paths used**:
- `secrets.ip.<host>.address` / `.gateway` — machine IPs
- `secrets.singBoxUsers` — list of proxy users with `uuid`, `name`, `password`, `hosts`
- `secrets.wireguard.mokosh-pubkey` — WireGuard public key
- `secrets.xray.reality.publicKey` / `.shortIds` — Xray Reality keys
- `secrets.mtproxy.users` — MTProxy user secrets
- `secrets.miniflux.apiKey` — Miniflux API key
- `secrets.hashedPassword` — user login password hash
- `secrets.sshKey` — SSH authorized key

## Common Tasks

### Add New Role

1. Create `roles/<name>.nix` (or `roles/<category>/<name>.nix` with a `default.nix`)
2. Add `options.roles.<name>` with `mkEnableOption`
3. Implement under `config = mkIf cfg.enable`
4. No need to update imports — `roles/default.nix` auto-discovers it
5. Enable in machine config: `roles.<name>.enable = true`

### Add New Sub-Role (e.g., new proxy transport)

1. Create file under the appropriate `roles/<category>/` directory
2. If it's a directory, include a `default.nix` that imports sub-files
3. The auto-discovery picks it up automatically

### Modify Existing Service

1. Edit the role file under `roles/`
2. Run `nixfmt <file>`
3. Run `make check`
4. Test with `make switch` on target machine

### Add New Machine

1. Create `machines/<hostname>/default.nix` following the machine config pattern
2. Add to `flake.nix` `nixosConfigurations` with appropriate system and modules
3. Set `system.stateVersion = "25.11"`
4. Configure networking and roles
5. If machine needs per-machine overlays, add them inline in the `modules` list

### Add New Home-Manager Software

1. Create `home/software/<name>/default.nix` with `options.software.<name>.enable`
2. Import in `home/default.nix` imports list
3. Enable in the home-manager config in `flake.nix`

## CI

GitHub Actions workflows in `.github/workflows/`:
- `check.yml` — runs `nix flake check`
- `update-flake.yml` — automated flake input updates

## Error Handling

- NixOS modules handle errors through option types and assertions
- Use `mkIf` for conditional config
- Service failures appear in systemd journal

## Important Files

- `flake.nix` — Main entry point, defines all machines and home-manager configs
- `Makefile` — Common operations (unlock, deploy, check)
- `roles/default.nix` — Auto-discovers all role modules
- `secrets/default.nix` — Exports parsed secrets.json
- `secrets/.gitignore` — Prevents committing decrypted secrets
- `overlays/default.nix` — Global nixpkgs overlays
- `common/filter-proxy-users.nix` — Shared utility for proxy user filtering
