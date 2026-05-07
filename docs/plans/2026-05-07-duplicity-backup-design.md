# Duplicity Backups with Asymmetric GPG Encryption

## Goal

Add automated, encrypted backups to mokosh using duplicity with GPG asymmetric
encryption, backed by S3-compatible storage. The backup role is reusable so
veles and nixpi can adopt it later.

## Requirements

- Duplicity with asymmetric GPG encryption (new ed25519 key, passphrase-less
  public key for encryption; private key kept offline)
- S3-compatible third-party storage
- `pg_dump` for PostgreSQL databases before backup
- Daily frequency, monthly full backup, keep last 3 full backups
- Reusable `roles.backup` module
- Each service role injects its own backup paths into `roles.backup`

## Architecture

### Role-injected paths

Each service role pushes its data paths and databases to `roles.backup`. Nix
module list merging collects them automatically. Machine config only sets
S3/GPG/retention parameters.

```
roles/vault.nix       → roles.backup.paths += [ "/var/lib/vault" ]
roles/communication/mail.nix → roles.backup.paths += [ "/var/lib/stalwart-mail" ]
roles/reading/rss/miniflux.nix → roles.backup.databases += [ "miniflux" ]
...etc

roles/backup.nix reads roles.backup.paths and roles.backup.databases
  → configures services.duplicity.include + pg_dump pre-backup service
```

### Components

1. **`roles/backup.nix`** — reusable module wrapping `services.duplicity`
2. **Pre-backup service** — `backup-pgdump.service` runs `pg_dump` for each
   database in `cfg.databases`, outputs to `/var/lib/backup-staging/`
3. **GPG key import** — activation script imports public key into
   `/var/lib/duplicity/.gnupg/`
4. **Service role edits** — each role with persistent data adds its paths

## Role Options

```nix
roles.backup = {
  enable = mkEnableOption "duplicity backups";

  paths = mkOption {
    type = types.listOf types.str;
    default = [ ];
  };

  databases = mkOption {
    type = types.listOf types.str;
    default = [ ];
  };

  gpgPublicKey = mkOption {
    type = types.path;
    description = "Path to ASCII-armored GPG public key for encryption";
  };

  gpgKeyId = mkOption {
    type = types.str;
    description = "GPG key fingerprint for --encrypt-key";
  };

  s3 = {
    endpoint = mkOption { type = types.str; };
    bucket = mkOption { type = types.str; };
    prefix = mkOption { type = types.str; };
  };

  frequency = mkOption {
    type = types.nullOr types.str;
    default = "daily";
  };

  fullIfOlderThan = mkOption {
    type = types.str;
    default = "1M";
  };

  maxFull = mkOption {
    type = types.int;
    default = 3;
  };
};
```

## Pre-backup: pg_dump

A systemd service `backup-pgdump` that:

- Runs `pg_dump` for each database in `cfg.databases`
- Outputs compressed SQL to `/var/lib/backup-staging/{db}.sql.gz`
- Runs before `duplicity.service` (`before` + `requiredBy`)
- Both triggered by the duplicity timer

Duplicity's `include` list gets `cfg.paths ++ [ "/var/lib/backup-staging" ]`.

## GPG Key Import

`system.activationScripts` snippet:

- Creates `/var/lib/duplicity/.gnupg/` (mode 700)
- Imports `cfg.gpgPublicKey` into duplicity's keyring

The GPG key is ed25519, encryption-only, no passphrase on the public key.
Private key is kept offline (not on server).

## Secrets

New secret file `/etc/nixos/secrets/duplicity-env`:

```
AWS_ACCESS_KEY_ID=<key>
AWS_SECRET_ACCESS_KEY=<secret>
```

Mapped via `services.duplicity.secretFile`. No `PASSPHRASE` needed (public-key-
only encryption).

Add `s3.accessKeyId` and `s3.secretAccessKey` to `secrets/secrets.json`.

## Mokosh Machine Config

```nix
# machines/mokosh/default.nix
imports = [ ... ../../roles/backup.nix ];

roles.backup = {
  enable = true;
  gpgPublicKey = ../../assets/backup-gpg-public.asc;
  gpgKeyId = "ABCD1234...";
  s3 = {
    endpoint = "https://...";
    bucket = "my-backups";
    prefix = "mokosh";
  };
};
```

No explicit paths needed — they come from enabled roles.

## Files Changed

| File | Action |
|------|--------|
| `roles/backup.nix` | Create |
| `roles/vault.nix` | Edit — add `roles.backup.paths` |
| `roles/communication/mail.nix` | Edit — add `roles.backup.paths` |
| `roles/reading/rss/miniflux.nix` | Edit — add `roles.backup.databases` |
| `roles/communication/dav.nix` | Edit — add `roles.backup.paths` |
| `roles/blog.nix` | Edit — add `roles.backup.paths` |
| `roles/reading/calibre.nix` | Edit — add `roles.backup.paths` |
| `machines/mokosh/default.nix` | Edit — import + configure |
| `assets/backup-gpg-public.asc` | Create (manual GPG keygen) |

## Backup Paths by Role

| Role | Path | Type |
|------|------|------|
| vault | `/var/lib/vault` | Files (SQLite, attachments) |
| mail | `/var/lib/stalwart-mail` | RocksDB |
| rss/miniflux | `pg_dump miniflux` → `/var/lib/backup-staging/` | PostgreSQL |
| dav | `/var/lib/radicale/collections` | Files |
| blog | `/var/lib/writefreely` | SQLite |
| calibre | `/var/lib/calibre-web/calibre` | SQLite + files |
| backup (staging) | `/var/lib/backup-staging` | pg_dump output |

## Restore (Manual)

```bash
# Import private key
gpg --homedir /var/lib/duplicity/.gnupg --import private-key.asc

# List backups
duplicity collection-status s3://endpoint/bucket/prefix

# Full restore
duplicity s3://endpoint/bucket/prefix /restore/target

# Specific file
duplicity --path-to-restore var/lib/vault/db.sqlite3 \
  s3://endpoint/bucket/prefix /restore/target

# Restore PostgreSQL
gunzip -c /restore/target/var/lib/backup-staging/miniflux.sql.gz | \
  sudo -u postgres psql miniflux
```

## GPG Key Generation (One-time)

```bash
gpg --batch --gen-key <<EOF
%no-protection
Key-Type: ed25519
Key-Usage: encrypt
Name-Real: mokosh-backup
Expire-Date: 0
EOF

gpg --armor --export <KEY_ID> > assets/backup-gpg-public.asc
# Store private key securely offline
```
