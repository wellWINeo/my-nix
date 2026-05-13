# Restic Backup Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace duplicity with restic in `roles/backup.nix`, using symmetric encryption via passwordFile, same S3 bucket, and a `backup.target` systemd target to orchestrate pre-backup services.

**Architecture:** Rewrite `roles/backup.nix` to use `services.restic.backups` instead of `services.duplicity`. Create `systemd.targets.backup` that collects pre-backup services via `WantedBy`/`Before`. Restic service depends on this target. Pre-backup service timers are disabled. Role authors' interface (`roles.backup.paths`, `roles.backup.afterServices`) stays unchanged.

**Tech Stack:** NixOS modules, restic, S3 (Yandex Cloud), systemd targets

**Design doc:** `docs/plans/2026-05-13-restic-backup-design.md`

---

### Task 1: Rewrite `roles/backup.nix`

**Files:**
- Rewrite: `roles/backup.nix`

**Step 1: Write the new module**

Replace entire file with:

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
in
{
  options.roles.backup = {
    enable = mkEnableOption "restic backups";

    paths = mkOption {
      type = types.listOf types.str;
      default = [ ];
    };

    repository = mkOption {
      type = types.str;
      description = "Restic repository URL (e.g. s3:storage.yandexcloud.net/bucket/prefix)";
    };

    exclude = mkOption {
      type = types.listOf types.str;
      default = [ ];
    };

    pruneOpts = mkOption {
      type = types.listOf types.str;
      default = [
        "--keep-daily 7"
        "--keep-monthly 3"
      ];
    };

    extraBackupArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
    };

    frequency = mkOption {
      type = types.nullOr types.str;
      default = "00:00";
    };

    afterServices = mkOption {
      type = types.listOf types.str;
      default = [ ];
      internal = true;
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.paths != [ ];
        message = "roles.backup: at least one path must be set";
      }
    ];

    systemd.targets.backup = { };

    services.restic.backups.mokosh = {
      repository = cfg.repository;
      passwordFile = "/etc/nixos/secrets/restic-password";
      environmentFile = "/etc/nixos/secrets/duplicity-env";
      initialize = true;
      inherit (cfg) paths exclude;
      extraBackupArgs = cfg.extraBackupArgs;
      pruneOpts = cfg.pruneOpts;
      timerConfig = mkIf (cfg.frequency != null) {
        OnCalendar = cfg.frequency;
        Persistent = true;
      };
    };

    systemd.services.restic-backups-mokosh = {
      after = [ "backup.target" ];
      requires = [ "backup.target" ];
    };

    systemd.services = listToAttrs (
      map (svc: {
        name = svc;
        value = {
          before = [ "backup.target" ];
          wantedBy = [ "backup.target" ];
        };
      }) cfg.afterServices
    );

    systemd.timers = listToAttrs (
      map (svc: {
        name = svc;
        value.enable = false;
      }) cfg.afterServices
    );
  };
}
```

**Step 2: Format**

Run: `nixfmt roles/backup.nix`

**Step 3: Commit**

```bash
git add roles/backup.nix
git commit -m "feat(backup): replace duplicity with restic + backup.target orchestration"
```

---

### Task 2: Update mokosh machine config

**Files:**
- Modify: `machines/mokosh/default.nix:217-226`

**Step 1: Replace `roles.backup` block**

In `machines/mokosh/default.nix`, replace lines 217-226:

Old:
```nix
  roles.backup = {
    enable = true;
    gpgPublicKey = ../../common/backup-gpg-public.asc;
    gpgKeyId = "AC99246D656181EFE5BF18C9D4C62D97193EF180";
    targetUrl = "s3:///wellwineo-backups/mokosh";
    extraFlags = [
      "--s3-endpoint-url=https://storage.yandexcloud.net"
      "--s3-region-name=ru-central1"
    ];
  };
```

New:
```nix
  roles.backup = {
    enable = true;
    repository = "s3:storage.yandexcloud.net/wellwineo-backups/mokosh";
  };
```

Note: The S3 endpoint URL and region are no longer needed as separate flags — restic
derives them from the `s3:` URL scheme. `AWS_DEFAULT_REGION` can go in the env file
if needed, but restic defaults to `us-east-1` and Yandex Cloud accepts that for
listing. If it causes issues, add `AWS_DEFAULT_REGION=ru-central1` to
`duplicity-env`.

**Step 2: Commit**

```bash
git add machines/mokosh/default.nix
git commit -m "feat(backup): update mokosh config for restic"
```

---

### Task 3: Add restic-password to secrets spec

**Files:**
- Modify: `secrets/unlocked/spec.txt`

**Step 1: Add new entry**

Append to `secrets/unlocked/spec.txt`:

```
mokosh:restic-password:0400:root:root
```

**Step 2: Commit**

```bash
git add secrets/unlocked/spec.txt
git commit -m "feat(backup): add restic-password secret spec"
```

---

### Task 4: Rewrite `docs/backups.md`

**Files:**
- Rewrite: `docs/backups.md`

**Step 1: Replace entire file with restic commands**

```markdown
# Backup Cheat Sheet

## Restore commands

Set S3 credentials:

```bash
export AWS_ACCESS_KEY_ID=<key>
export AWS_SECRET_ACCESS_KEY=<secret>
```

```bash
REPO="s3:storage.yandexcloud.net/wellwineo-backups/mokosh"
export RESTIC_PASSWORD_FILE=/etc/nixos/secrets/restic-password
```

### List available snapshots

```bash
restic -r $REPO snapshots
```

### List files in latest snapshot

```bash
restic -r $REPO ls latest
```

### Restore a single path

```bash
restic -r $REPO restore latest --target /tmp/restore --include var/backup/vaultwarden
```

### Restore from a specific snapshot

```bash
restic -r $REPO restore <snapshot-id> --target /tmp/restore
```

### Full restore

```bash
restic -r $REPO restore latest --target /tmp/full-restore
```

### Verify backup integrity

```bash
restic -r $REPO check
```

## Restore by service

### Vaultwarden

```bash
restic -r $REPO restore latest --target /tmp/restore --include var/backup/vaultwarden
cp -r /tmp/restore/var/backup/vaultwarden/* /var/lib/vault/
systemctl restart vaultwarden
```

### Miniflux (PostgreSQL)

```bash
restic -r $REPO restore latest --target /tmp/restore --include var/backup/miniflux/miniflux.sql.gz
gunzip -c /tmp/restore/var/backup/miniflux/miniflux.sql.gz | sudo -u postgres psql miniflux
systemctl restart miniflux
```

### Calibre

```bash
restic -r $REPO restore latest --target /tmp/restore --include var/backup/calibre
rsync -a /tmp/restore/var/backup/calibre/ /var/lib/calibre/
systemctl restart calibre-web
```

### Writefreely

```bash
restic -r $REPO restore latest --target /tmp/restore --include var/backup/writefreely
rsync -a /tmp/restore/var/backup/writefreely/ /var/lib/writefreely/
systemctl restart writefreely
```

### Stalwart mail

```bash
restic -r $REPO restore latest --target /tmp/restore --include var/lib/stalwart-mail
systemctl stop stalwart-mail
rsync -a /tmp/restore/var/lib/stalwart-mail/ /var/lib/stalwart-mail/
systemctl start stalwart-mail
```

## Backup schedule

| Service | Trigger | What |
|---------|---------|------|
| vaultwarden | backup.target | sqlite .backup + file copy |
| calibre | backup.target | sqlite .backup (3 DBs) + rsync books |
| writefreely | backup.target | sqlite .backup + rsync files |
| miniflux | backup.target | pg_dump gzip |
| restic | 00:00 daily | encrypted deduplicated to S3 |

All pre-backup services run in parallel when the restic timer fires.
The restic backup starts after all prep services complete.

## Notes

- Backup data on S3 is restic-encrypted, not directly browseable
- The restic password is in `/etc/nixos/secrets/restic-password`
- `AWS_DEFAULT_REGION=ru-central1` is mandatory for Yandex Cloud (set in duplicity-env)
- Old duplicity backup data remains in the same S3 prefix; clean up manually after verifying restic works
```

**Step 2: Commit**

```bash
git add docs/backups.md
git commit -m "docs: update backup cheat sheet for restic"
```

---

### Task 5: Remove GPG public key file

**Files:**
- Remove: `common/backup-gpg-public.asc`

**Step 1: Delete and commit**

```bash
git rm common/backup-gpg-public.asc
git commit -m "chore: remove duplicity GPG public key (replaced by restic symmetric encryption)"
```

---

### Task 6: Validate with `nix flake check`

**Step 1: Ensure dummy secrets exist**

```bash
make setup-dummy-secrets
```

**Step 2: Format all changed files**

```bash
nixfmt roles/backup.nix machines/mokosh/default.nix
```

**Step 3: Run flake check**

```bash
make check
```

Expected: passes without errors.

**Step 4: Fix any issues, then commit fixes if needed**
