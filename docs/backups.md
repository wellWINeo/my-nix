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
