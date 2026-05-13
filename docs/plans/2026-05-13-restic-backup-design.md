# Restic Backup Migration (Duplicity → Restic)

## Goal

Replace duplicity with restic on mokosh, keeping the same S3 bucket and
credentials. Switch from GPG asymmetric encryption to symmetric encryption via
`passwordFile`. Introduce a `backup.target` systemd target to orchestrate
pre-backup services instead of relying on timer timing overlaps.

## Requirements

- Restic with symmetric encryption (password file)
- Same S3 bucket: `s3:storage.yandexcloud.net/wellwineo-backups/mokosh`
- Same S3 credentials (reuse `duplicity-env` file)
- Same S3 prefix (restic init alongside old duplicity data)
- Fresh restic repo — old duplicity snapshots left in S3 for later cleanup
- `backup.target` systemd target replaces individual pre-backup timers
- Single restic timer triggers the entire chain
- Reusable `roles.backup` module interface unchanged for role authors

## Architecture

### backup.target orchestration

Old flow (duplicity): each pre-backup service has its own timer; duplicity
service has `After`/`Requires` on them. Daily timing overlap makes it work —
fragile and implicit.

New flow (restic + target):

1. `roles/backup.nix` creates `systemd.targets.backup`
2. For each service in `cfg.afterServices`, the module sets:
   - `systemd.services.<name>.before = ["backup.target"]`
   - `systemd.services.<name>.wantedBy = ["backup.target"]`
   - `systemd.timers.<name>.enable = false`
3. Restic service gets `After = ["backup.target"]`, `Requires = ["backup.target"]`
4. One timer (restic) triggers the chain

```
restic timer fires → restic-backups-mokosh.service
  → requires backup.target
    → target wants all prep services (vaultwarden, miniflux, calibre, writefreely)
    → prep services have Before=backup.target, run first (in parallel)
  → once target active, restic proceeds
```

### Role interface (unchanged)

Roles push to `roles.backup.paths` and `roles.backup.afterServices` as before.
No changes needed in vault, miniflux, calibre, blog, mail roles.

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | false | Enable restic backups |
| `paths` | list str | [] | Paths to back up |
| `repository` | str | required | Restic repo URL |
| `exclude` | list str | [] | Exclude patterns |
| `pruneOpts` | list str | see below | Retention policy |
| `extraBackupArgs` | list str | [] | Extra restic backup args |
| `afterServices` | list str | [] | Prep services (internal) |
| `timerConfig` | attrs | `{ OnCalendar = "00:00"; Persistent = true; }` | Timer config |
| `frequency` | nullOr str | null | Shorthand for timerConfig.OnCalendar |

Default pruneOpts:
```nix
[ "--keep-daily 7" "--keep-monthly 3" ]
```

## Secrets

| Secret | File | Contents |
|--------|------|----------|
| S3 creds | `/etc/nixos/secrets/duplicity-env` | `AWS_ACCESS_KEY_ID=...` / `AWS_SECRET_ACCESS_KEY=...` (unchanged) |
| Repo password | `/etc/nixos/secrets/restic-password` (new) | Single line plaintext |
| spec.txt entry | `mokosh:restic-password:0400:root:root` | (new) |

## Files Changed

| File | Action |
|------|--------|
| `roles/backup.nix` | Rewrite — duplicity → restic |
| `machines/mokosh/default.nix` | Edit — update `roles.backup` options |
| `secrets/unlocked/spec.txt` | Add `restic-password` entry |
| `docs/backups.md` | Rewrite — restic restore commands |
| `common/backup-gpg-public.asc` | Remove |

## Files NOT Changed

Pre-backup service definitions in roles (vault, miniflux, calibre, blog, mail)
continue to push to `roles.backup.paths` and `roles.backup.afterServices`.
Their individual timers get disabled by `roles/backup.nix` — no edits needed.

## Mokosh Machine Config

```nix
roles.backup = {
  enable = true;
  repository = "s3:storage.yandexcloud.net/wellwineo-backups/mokosh";
  pruneOpts = [
    "--keep-daily 7"
    "--keep-monthly 3"
  ];
};
```
