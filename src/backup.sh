#! /bin/sh

set -eu
set -o pipefail

source ./env.sh

BACKUP_MODE=$(printf '%s' "${BACKUP_MODE:-db}" | tr -d '[:space:]')

if [ -z "$BACKUP_MODE" ]; then
  BACKUP_MODE=db
fi

validate_backup_mode() {
  mode_count=0
  for mode in $(printf '%s' "$BACKUP_MODE" | tr ',' ' '); do
    case "$mode" in
      db|dir)
        mode_count=$((mode_count + 1))
        ;;
      *)
        echo "You need to set BACKUP_MODE to db, dir, or db,dir."
        exit 1
        ;;
    esac
  done

  if [ "$mode_count" -eq 0 ]; then
    echo "You need to set BACKUP_MODE to db, dir, or db,dir."
    exit 1
  fi
}

upload_file() {
  local_file="$1"
  s3_uri="$2"

  echo "Uploading backup to $S3_BUCKET..."
  aws $aws_args s3 cp "$local_file" "$s3_uri"
  rm "$local_file"
}

encrypt_file() {
  input_file="$1"

  echo "Encrypting backup..."
  rm -f "${input_file}.gpg"
  gpg --symmetric --batch --passphrase "$PASSPHRASE" "$input_file"
  rm "$input_file"
}

backup_dir() {
  if [ -z "$BACKUP_DIR" ]; then
    echo "You need to set the BACKUP_DIR environment variable when BACKUP_MODE includes dir."
    exit 1
  fi

  if [ ! -d "$BACKUP_DIR" ]; then
    echo "BACKUP_DIR must point to an existing directory."
    exit 1
  fi

  dir_parent=$(dirname "$BACKUP_DIR")
  dir_name=$(basename "$BACKUP_DIR")

  if [ -z "$dir_name" ] || [ "$dir_name" = "." ] || [ "$dir_name" = "/" ]; then
    echo "BACKUP_DIR must point to a named directory."
    exit 1
  fi

  echo "Creating backup of directory $BACKUP_DIR..."
  rm -f dir.tar.gz
  tar -czf dir.tar.gz -C "$dir_parent" "$dir_name"

  s3_uri_base="s3://${S3_BUCKET}/${S3_PREFIX}/dir/${dir_name}_${backup_timestamp}.tar.gz"

  if [ -n "$PASSPHRASE" ]; then
    encrypt_file dir.tar.gz
    upload_file dir.tar.gz.gpg "${s3_uri_base}.gpg"
  else
    upload_file dir.tar.gz "$s3_uri_base"
  fi

  echo "Directory backup complete."
}

backup_db() {
  echo "Creating backup of $POSTGRES_DATABASE database..."
  rm -f db.dump
  pg_dump --format=custom \
    -h "$POSTGRES_HOST" \
    -p "$POSTGRES_PORT" \
    -U "$POSTGRES_USER" \
    -d "$POSTGRES_DATABASE" \
    $PGDUMP_EXTRA_OPTS \
    > db.dump

  s3_uri_base="s3://${S3_BUCKET}/${S3_PREFIX}/${POSTGRES_DATABASE}_${backup_timestamp}.dump"

  if [ -n "$PASSPHRASE" ]; then
    encrypt_file db.dump
    upload_file db.dump.gpg "${s3_uri_base}.gpg"
  else
    upload_file db.dump "$s3_uri_base"
  fi

  echo "Database backup complete."
}

validate_backup_mode

backup_timestamp=$(date +"%Y-%m-%dT%H:%M:%S")

case ",$BACKUP_MODE," in
  *,dir,*) backup_dir ;;
esac

case ",$BACKUP_MODE," in
  *,db,*) backup_db ;;
esac

if [ -n "$BACKUP_KEEP_DAYS" ]; then
  sec=$((86400*BACKUP_KEEP_DAYS))
  date_from_remove=$(date -d "@$(($(date +%s) - sec))" +%Y-%m-%d)
  backups_query="Contents[?LastModified<='${date_from_remove} 00:00:00'].Key"
  backup_keys=$(
    aws $aws_args s3api list-objects-v2 \
      --bucket "${S3_BUCKET}" \
      --prefix "${S3_PREFIX}" \
      --query "${backups_query}" \
      --output text
  )

  echo "Removing old backups from $S3_BUCKET..."
  if [ -n "$backup_keys" ] && [ "$backup_keys" != "None" ]; then
    printf '%s\n' "$backup_keys" \
      | tr '\t' '\n' \
      | while IFS= read -r key; do
          if [ -n "$key" ]; then
            aws $aws_args s3 rm "s3://${S3_BUCKET}/${key}"
          fi
        done
  fi
  echo "Removal complete."
fi

echo "Backup complete."
