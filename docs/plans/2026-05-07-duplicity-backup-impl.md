# Duplicity Backup Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create a reusable `roles.backup` module using duplicity with asymmetric GPG encryption, backed by S3-compatible storage, for mokosh. Service roles inject their own backup paths.

**Architecture:** A single `roles/backup.nix` wraps NixOS's `services.duplicity`. Each service role pushes paths to `roles.backup.paths` / `roles.backup.databases`. A pre-backup systemd service dumps PostgreSQL databases. GPG public key is imported via activation script.

**Tech Stack:** NixOS modules, duplicity, GPG, S3-compatible storage, systemd timers, pg_dump

**Design doc:** `docs/plans/2026-05-07-duplicity-backup-design.md`

---

## Pre-flight: Create feature branch

Currently on `main`. Create branch before any edits.

```bash
git checkout -b feat/duplicity-backup
```

---

### Task 1: Create `roles/backup.nix` — the core module

**Files:**
- Create: `roles/backup.nix`

**Step 1: Write the role module**

Create `roles/backup.nix` with the full module. This is the central piece — it defines options for S3 target, GPG key, paths/databases (collectable), retention, and wires everything into `services.duplicity` plus a `backup-pgdump` systemd service.

```nix
{
  config,
  lib,
  pkgs,
  ...
}:
with lib;

let
  cfg = config.roles.backup;

  stagingDir = "/var/lib/backup-staging";
  gpgHome = "/var/lib/duplicity/.gnupg";

  hasDatabases = cfg.databases != [ ];
  hasPaths = cfg.paths != [ ];

  s3Url =
    let
      endpoint = lib.strings.removePrefix "https://" cfg.s3.endpoint;
    in
    "s3://${endpoint}/${cfg.s3.bucket}/${cfg.s3.prefix}";
in
{
  options.roles.backup = {
    enable = mkEnableOption "duplicity backups";

    paths = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Paths to back up. Other roles push to this list.";
    };

    databases = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "PostgreSQL databases to pg_dump before backup.";
    };

    gpgPublicKey = mkOption {
      type = types.path;
      description = "Path to ASCII-armored GPG public key for encryption";
    };

    gpgKeyId = mkOption {
      type = types.str;
      description = "GPG key fingerprint or ID for --encrypt-key";
    };

    s3 = {
      endpoint = mkOption {
        type = types.str;
        description = "S3 endpoint URL (e.g. https://s3.example.com)";
      };
      bucket = mkOption {
        type = types.str;
        description = "S3 bucket name";
      };
      prefix = mkOption {
        type = types.str;
        description = "Path prefix inside the bucket";
      };
    };

    frequency = mkOption {
      type = types.nullOr types.str;
      default = "daily";
      description = "systemd calendar expression for backup schedule. null disables timer.";
    };

    fullIfOlderThan = mkOption {
      type = types.str;
      default = "1M";
      description = "Create a new full backup when the last full is older than this";
    };

    maxFull = mkOption {
      type = types.int;
      default = 3;
      description = "Keep only the last N full backups and associated incrementals";
    };

    exclude = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Paths to exclude from backup";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = hasPaths || hasDatabases;
        message = "roles.backup: at least one of paths or databases must be set";
      }
    ];

    system.activationScripts.backup-gnupg = ''
      mkdir -p ${gpgHome}
      chmod 700 ${gpgHome}
      if [ ! -f ${gpgHome}/pubring.kbx ] || ! ${pkgs.gnupg}/bin/gpg --homedir ${gpgHome} --list-keys "${cfg.gpgKeyId}" >/dev/null 2>&1; then
        ${pkgs.gnupg}/bin/gpg --homedir ${gpgHome} --import ${cfg.gpgPublicKey}
      fi
    '';

    systemd.services.backup-pgdump = mkIf hasDatabases {
      description = "Dump PostgreSQL databases for backup";
      path = [ pkgs.postgresql_16 ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "backup-pgdump" ''
          set -euo pipefail
          mkdir -p ${stagingDir}
          ${concatStringsSep "\n" (
            map (db: ''
              pg_dump ${db} | gzip > ${stagingDir}/${db}.sql.gz.tmp
              mv ${stagingDir}/${db}.sql.gz.tmp ${stagingDir}/${db}.sql.gz
            '') cfg.databases
          )}
        '';
        User = "postgres";
        Group = "postgres";
      };
    };

    services.duplicity =
      let
        allIncludes =
          cfg.paths
          ++ optionals hasDatabases [ stagingDir ];
      in
      {
        enable = true;
        root = "/";
        include = allIncludes;
        exclude = cfg.exclude ++ [ "**" ];
        targetUrl = s3Url;
        secretFile = "/etc/nixos/secrets/duplicity-env";
        frequency = cfg.frequency;
        fullIfOlderThan = cfg.fullIfOlderThan;
        extraFlags = [
          "--encrypt-key"
          cfg.gpgKeyId
          "--gpg-options=--homedir ${gpgHome}"
          "--verbosity"
          "notice"
          "--num-retries"
          "3"
          "--volsize"
          "100"
        ];
        cleanup.maxFull = cfg.maxFull;
      };

    systemd.services.duplicity =
      let
        needsPgDump = hasDatabases;
      in
      mkMerge [
        (mkIf needsPgDump {
          after = [ "backup-pgdump.service" ];
          requires = [ "backup-pgdump.service" ];
        })
        {
          serviceConfig.Environment = [
            "AWS_ENDPOINT=${cfg.s3.endpoint}"
          ];
        }
      ];

    systemd.timers.duplicity = mkIf (cfg.frequency != null) {
      timerConfig.Persistent = true;
    };
  };
}
```

**Step 2: Run `nixfmt`**

```bash
nixfmt roles/backup.nix
```

**Step 3: Verify it parses**

```bash
nix eval --impure --expr 'import ./roles/backup.nix { config = {}; lib = import <nixpkgs/lib> {}; pkgs = {}; }' 2>&1 || true
```

This may fail due to missing module system args — that's expected. The real check is `nix flake check`.

**Step 4: Commit**

```bash
git add roles/backup.nix
git commit -m "feat(backup): add roles.backup module with duplicity + GPG + pg_dump"
```

---

### Task 2: Inject backup paths from service roles (6 files)

Each role adds its backup paths inside its existing `config = mkIf cfg.enable` block. This is a one-line addition per file.

**Files:**
- Modify: `roles/vault.nix:23` (inside `config = mkIf cfg.enable {`)
- Modify: `roles/communication/mail.nix:51`
- Modify: `roles/communication/dav.nix:16`
- Modify: `roles/blog.nix:29`
- Modify: `roles/reading/calibre.nix:18`
- Modify: `roles/reading/rss/miniflux.nix:22`

**Step 1: Add backup paths to each role**

In each file, add the `roles.backup.paths` or `roles.backup.databases` line as the **first line inside** `config = mkIf cfg.enable {`:

**`roles/vault.nix`** — add at line 24 (first line inside the `mkIf cfg.enable` block):
```nix
    roles.backup.paths = [ "/var/lib/vault" ];
```

**`roles/communication/mail.nix`** — add at line 52:
```nix
    roles.backup.paths = [ "/var/lib/stalwart-mail" ];
```

**`roles/communication/dav.nix`** — add at line 17:
```nix
    roles.backup.paths = [ "/var/lib/radicale/collections" ];
```

**`roles/blog.nix`** — add at line 30:
```nix
    roles.backup.paths = [ "/var/lib/writefreely" ];
```

**`roles/reading/calibre.nix`** — add at line 19:
```nix
    roles.backup.paths = [ "/var/lib/calibre-web/calibre" ];
```

**`roles/reading/rss/miniflux.nix`** — add at line 23:
```nix
    roles.backup.databases = [ "miniflux" ];
```

**Step 2: Format all changed files**

```bash
nixfmt roles/vault.nix roles/communication/mail.nix roles/communication/dav.nix roles/blog.nix roles/reading/calibre.nix roles/reading/rss/miniflux.nix
```

**Step 3: Commit**

```bash
git add roles/vault.nix roles/communication/mail.nix roles/communication/dav.nix roles/blog.nix roles/reading/calibre.nix roles/reading/rss/miniflux.nix
git commit -m "feat(backup): inject backup paths from service roles"
```

---

### Task 3: Wire up mokosh machine config

**Files:**
- Modify: `machines/mokosh/default.nix:17` (imports list) and `:229` (after roles.dav)

**Step 1: Add backup role import**

Add `../../roles/backup.nix` to the imports list in `machines/mokosh/default.nix`, after `../../roles/blog.nix` (line 31):

```nix
    ../../roles/backup.nix
```

**Step 2: Add backup role config**

After the `roles.dav` block (line 229), add:

```nix
  roles.backup = {
    enable = true;
    gpgPublicKey = ../../assets/backup-gpg-public.asc;
    gpgKeyId = "REPLACE_WITH_GPG_KEY_ID";
    s3 = {
      endpoint = "https://REPLACE_WITH_S3_ENDPOINT";
      bucket = "REPLACE_WITH_BUCKET_NAME";
      prefix = "mokosh";
    };
  };
```

Note: `gpgKeyId`, `s3.endpoint`, and `s3.bucket` have placeholder values that must be replaced with real values after GPG key generation and S3 bucket setup.

**Step 3: Format**

```bash
nixfmt machines/mokosh/default.nix
```

**Step 4: Commit**

```bash
git add machines/mokosh/default.nix
git commit -m "feat(backup): enable roles.backup on mokosh"
```

---

### Task 4: Update secrets infrastructure

**Files:**
- Modify: `secrets/unlocked/spec.txt` — add duplicity-env entry
- Modify: `secrets/secrets.dummy.json` — add S3 placeholder keys

**Step 1: Add file-based secret for duplicity env**

Append to `secrets/unlocked/spec.txt`:

```
mokosh:duplicity-env:0400:root:root
```

The actual file `secrets/unlocked/duplicity-env` must contain:
```
AWS_ACCESS_KEY_ID=<real-key>
AWS_SECRET_ACCESS_KEY=<real-secret>
```

This is a manual step done during `make unlock` + editing.

**Step 2: Update dummy secrets**

Add to `secrets/secrets.dummy.json` (inside the top-level object, after the `miniflux` key):

```json
  "s3": {
    "accessKeyId": "dummy-access-key-id",
    "secretAccessKey": "dummy-secret-access-key"
  }
```

**Step 3: Commit**

```bash
git add secrets/unlocked/spec.txt secrets/secrets.dummy.json
git commit -m "feat(backup): add duplicity-env secret spec and dummy S3 credentials"
```

---

### Task 5: Create GPG public key placeholder

**Files:**
- Create: `assets/backup-gpg-public.asc`

**Step 1: Generate GPG key and export public key**

This is a manual step the user performs locally:

```bash
gpg --batch --gen-key <<EOF
%no-protection
Key-Type: ed25519
Key-Usage: encrypt
Name-Real: mokosh-backup
Expire-Date: 0
EOF

gpg --armor --export "mokosh-backup" > assets/backup-gpg-public.asc
```

Then update `machines/mokosh/default.nix` with the real key fingerprint:
```bash
gpg --list-keys --keyid-format long "mokosh-backup"
```

Copy the fingerprint into `roles.backup.gpgKeyId` in mokosh's config.

**Step 2: Commit**

```bash
git add assets/backup-gpg-public.asc
git commit -m "feat(backup): add GPG public key for backup encryption"
```

---

### Task 6: Validate with `nix flake check`

**Step 1: Setup dummy secrets if needed**

```bash
make setup-dummy-secrets
```

**Step 2: Run flake check**

```bash
make check
```

Expected: passes with no errors. If there are eval errors in the new module, fix them and re-run.

**Step 3: Fix any issues and re-format**

```bash
nixfmt .
make check
```

**Step 4: Commit any fixes**

```bash
git add -u
git commit -m "fix(backup): resolve flake check issues"
```

---

## Post-implementation checklist

- [ ] GPG key generated and public key committed to `assets/`
- [ ] Real `gpgKeyId` set in mokosh config (not placeholder)
- [ ] Real `s3.endpoint` and `s3.bucket` set in mokosh config (not placeholder)
- [ ] `duplicity-env` secret file created in `secrets/unlocked/` with real S3 credentials
- [ ] `make check` passes
- [ ] Ready for `make switch` on mokosh (manual deployment)
- [ ] After deploy: verify `systemctl status duplicity.timer` and `systemctl start duplicity` manually
