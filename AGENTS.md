# AGENTS.md

Guide for AI coding agents working in this NixOS configuration repository.

## Project Overview

This is a NixOS configuration repository using Flakes to manage multiple machines:
- **mokosh**: Main VPS (website, mail, VPN, vault, blog)
- **veles**: Secondary VPS
- **nixpi**: Raspberry Pi 4 home server (media, NAS, DNS, DHCP)

## Build/Lint/Test Commands

```bash
# Check flake validity (syntax, eval)
make check
# Or directly:
nix flake check 'path:.' --all-systems

# Format all Nix files
nixfmt .

# Format specific file
nixfmt path/to/file.nix

# Enter dev shell (provides nixfmt, nixd)
nix develop

# Deploy to current machine
make switch

# Build without switching (dry run)
nixos-rebuild build --flake "path:.#$(hostname)"
```

Note: There are no automated tests. Validation is via `nix flake check` and manual deployment testing.

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
  # Local variables here
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

### Imports Pattern

Machine configs import from:
1. `../../common/` - Shared base configs
2. `../../hardware/` - Hardware-specific setup
3. `../../roles/` - Service modules
4. `../../users/` - User definitions

```nix
imports = [
  ../../common/hardened.nix
  ../../common/server.nix
  ../../hardware/vm.nix
  ../../roles/vault.nix
];
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

## Directory Purposes

| Directory | Purpose |
|-----------|---------|
| `machines/` | Per-machine NixOS configurations |
| `roles/` | Reusable service modules (nginx services, apps) |
| `common/` | Shared configs (server base, hardening) |
| `hardware/` | Hardware-specific configs (VM, RPi) |
| `users/` | User account definitions |
| `secrets/` | Encrypted secrets (gitignored) |
| `assets/` | Static files for services |

## Secrets

**Location**: `secrets/` directory (gitignored)

| File | Contents |
|------|----------|
| `secrets.json.gpg` | Key-value secrets (passwords, tokens, keys) |
| `locked.tar.gpg` | File-based secrets (certs, env files) |

**Commands**:
```bash
make unlock      # Decrypt all secrets
make lock        # Re-encrypt secrets
make install-secrets  # Copy to /etc/nixos/secrets/
```

**Access pattern**:
```nix
secrets = import ../../secrets;
# secrets.json is JSON object with all secrets
```

## Common Tasks

### Add New Role

1. Create `roles/<name>.nix` with options pattern
2. Add `options.roles.<name>` with `mkEnableOption`
3. Implement under `config = mkIf cfg.enable`
4. Import in machine config and set `roles.<name>.enable = true`

### Modify Existing Service

1. Edit `roles/<service>.nix`
2. Run `nixfmt roles/<service>.nix`
3. Run `make check`
4. Test with `make switch` on target machine

### Add New Machine

1. Create `machines/<hostname>/default.nix`
2. Add to `flake.nix` nixosConfigurations
3. Set `system.stateVersion`
4. Configure networking and imports

## Error Handling

- NixOS modules handle errors through option types and assertions
- Use `mkIf` for conditional config
- Service failures appear in systemd journal

## Important Files

- `flake.nix` - Main entry point, defines all machines
- `Makefile` - Common operations
- `secrets/default.nix` - Exports parsed secrets.json
- `secrets/.gitignore` - Prevents committing decrypted secrets
