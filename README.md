# Introduction
This project provides Docker images to periodically back up a PostgreSQL database to AWS S3, and to restore from the backup as needed.

# Usage
## Backup
```yaml
services:
  postgres:
    image: postgres:18
    environment:
      POSTGRES_USER: user
      POSTGRES_PASSWORD: password

  backup:
    image: ghcr.io/tokisaki-galaxy/postgres-backup-s3:18
    environment:
      SCHEDULE: '@weekly'     # optional
      BACKUP_KEEP_DAYS: 7     # optional
      PASSPHRASE: passphrase  # optional
      S3_REGION: region
      S3_ACCESS_KEY_ID: key
      S3_SECRET_ACCESS_KEY: secret
      S3_BUCKET: my-bucket
      S3_PREFIX: backup
      BACKUP_MODE: db,dir
      BACKUP_DIR: /data
      POSTGRES_HOST: postgres
      POSTGRES_DATABASE: dbname
      POSTGRES_USER: user
      POSTGRES_PASSWORD: password
```

- Images are tagged only for the latest supported major PostgreSQL version: `18`.
- Release tags (e.g. `v1.2.3`) also publish versioned tags to GHCR in the form `ghcr.io/tokisaki-galaxy/postgres-backup-s3:v1.2.3-pg18`.
- The `SCHEDULE` variable determines backup frequency. See go-cron schedules documentation [here](http://godoc.org/github.com/robfig/cron#hdr-Predefined_schedules). Omit to run the backup immediately and then exit.
- If `PASSPHRASE` is provided, the backup will be encrypted using GPG.
- `BACKUP_MODE` can be `db`, `dir`, or `db,dir`. When both are enabled, the directory backup runs first.
- `BACKUP_DIR` is required when `BACKUP_MODE` includes `dir`. Directory backups are packed as `tar.gz` and uploaded under `S3_PREFIX/dir/`.
- Run `docker exec <container name> sh backup.sh` to trigger a backup ad-hoc.
- If `BACKUP_KEEP_DAYS` is set, backups older than this many days will be deleted from S3.
- Set `S3_ENDPOINT` if you're using a non-AWS S3-compatible storage provider.

## Restore
> [!CAUTION]
> DATA LOSS! All database objects will be dropped and re-created.

### ... from latest backup
```sh
docker exec <container name> sh restore.sh
```

> [!NOTE]
> `RESTORE_MODE` can be `db`, `dir`, or `db,dir`. Set `RESTORE_MODE=dir` to restore directory backups. Use `RESTORE_DIR` as the target path, and `RESTORE_SOURCE_NAME` if the backup source name differs from the target directory name.

```sh
docker exec -e RESTORE_MODE=dir -e RESTORE_DIR=/data <container name> sh restore.sh
```

> [!NOTE]
> Directory restore extracts into a temporary location first. Set `RESTORE_OVERWRITE=yes` if the target directory already has content.

> [!NOTE]
> If your bucket has more than a 1000 files, the latest may not be restored -- only one S3 `ls` command is used

### ... from specific backup
```sh
docker exec <container name> sh restore.sh <timestamp>
```

```sh
docker exec -e RESTORE_MODE=dir -e RESTORE_DIR=/data <container name> sh restore.sh <timestamp>
```

# Development
## Build the image locally
`ALPINE_VERSION` is fixed to `3.21` in CI for the latest `pg18` image.
```sh
DOCKER_BUILDKIT=1 docker build --build-arg ALPINE_VERSION=3.21 .
```
## Run a simple test environment with Docker Compose
```sh
cp template.env .env
# fill out your secrets/params in .env
docker compose up -d
```

# Acknowledgements
This project is a fork and re-structuring of @schickling's [postgres-backup-s3](https://github.com/schickling/dockerfiles/tree/master/postgres-backup-s3) and [postgres-restore-s3](https://github.com/schickling/dockerfiles/tree/master/postgres-restore-s3).

## Fork goals
These changes would have been difficult or impossible merge into @schickling's repo or similarly-structured forks.
  - dedicated repository
  - automated builds
  - support multiple PostgreSQL versions
  - backup and restore with one image

## Other changes and features
  - some environment variables renamed or removed
  - uses `pg_dump`'s `custom` format (see [docs](https://www.postgresql.org/docs/10/app-pgdump.html))
  - drop and re-create all database objects on restore
  - backup blobs and all schemas by default
  - no Python 2 dependencies
  - filter backups on S3 by database name
  - support encrypted (password-protected) backups
  - support for restoring from a specific backup by timestamp
  - support for auto-removal of old backups
