# Backup Cheat Sheet

## Restore commands

All commands require the GPG private key imported into duplicity's keyring:

```bash
gpg --homedir /var/lib/duplicity/.gnupg --import private-key.asc
```

Set S3 credentials:

```bash
export AWS_ACCESS_KEY_ID=<key>
export AWS_SECRET_ACCESS_KEY=<secret>
export AWS_DEFAULT_REGION=ru-central1
```

```bash
BUCKET="s3://storage.yandexcloud.net/wellwineo-backups/mokosh"
```

### List available backups

```bash
duplicity collection-status $BUCKET
```

### List files in latest backup

```bash
duplicity list-current-files $BUCKET
```

### Restore a single file

```bash
duplicity --path-to-restore var/backup/vaultwarden/db.sqlite3 \
  $BUCKET /tmp/restore
```

### Restore from a specific date

```bash
duplicity -t 3D $BUCKET /tmp/restore
duplicity -t 2026-05-01 $BUCKET /tmp/restore
```

### Full restore

```bash
duplicity $BUCKET /tmp/full-restore
```

### Verify backup against local files

```bash
duplicity verify $BUCKET /tmp/full-restore
```

## Restore by service

### Vaultwarden

```bash
duplicity --path-to-restore var/backup/vaultwarden $BUCKET /tmp/restore
cp -r /tmp/restore/var/backup/vaultwarden/* /var/lib/vault/
systemctl restart vaultwarden
```

### Miniflux (PostgreSQL)

```bash
duplicity --path-to-restore var/backup/miniflux/miniflux.sql.gz $BUCKET /tmp/restore
gunzip -c /tmp/restore/var/backup/miniflux/miniflux.sql.gz | sudo -u postgres psql miniflux
systemctl restart miniflux
```

### Calibre

```bash
duplicity --path-to-restore var/backup/calibre $BUCKET /tmp/restore
rsync -a /tmp/restore/var/backup/calibre/ /var/lib/calibre/
systemctl restart calibre-web
```

### Writefreely

```bash
duplicity --path-to-restore var/backup/writefreely $BUCKET /tmp/restore
rsync -a /tmp/restore/var/backup/writefreely/ /var/lib/writefreely/
systemctl restart writefreely
```

### Stalwart mail

```bash
duplicity --path-to-restore var/lib/stalwart-mail $BUCKET /tmp/restore
systemctl stop stalwart-mail
rsync -a /tmp/restore/var/lib/stalwart-mail/ /var/lib/stalwart-mail/
systemctl start stalwart-mail
```

### Radicale

```bash
duplicity --path-to-restore var/lib/radicale/collections $BUCKET /tmp/restore
rsync -a /tmp/restore/var/lib/radicale/collections/ /var/lib/radicale/collections/
systemctl restart radicale
```

## Backup schedule

| Service | Timer | What |
|---------|-------|------|
| vaultwarden | 23:00 daily | sqlite .backup + file copy (built-in) |
| calibre | 23:00 daily | sqlite .backup (3 DBs) + rsync books |
| writefreely | 23:00 daily | sqlite .backup + rsync files |
| miniflux | 23:00 daily | pg_dump gzip |
| duplicity | 00:00 daily | encrypted incremental to S3 |

## Notes

- Backup files on S3 are GPG-encrypted volumes, not directly browseable
- Private key is needed for any restore operation
- Keep the private key offline (USB, paper backup, etc.)
- `AWS_DEFAULT_REGION=ru-central1` is mandatory for Yandex Cloud
