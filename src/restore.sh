#! /bin/sh

set -eu
set -o pipefail

source ./env.sh

RESTORE_MODE=$(printf '%s' "${RESTORE_MODE:-db}" | tr -d '[:space:]')
RESTORE_OVERWRITE=$(printf '%s' "${RESTORE_OVERWRITE:-no}" | tr -d '[:space:]')

if [ -z "$RESTORE_MODE" ]; then
  RESTORE_MODE=db
fi

validate_restore_mode() {
  mode_count=0
  for mode in $(printf '%s' "$RESTORE_MODE" | tr ',' ' '); do
    case "$mode" in
      db|dir)
        mode_count=$((mode_count + 1))
        ;;
      *)
        echo "You need to set RESTORE_MODE to db, dir, or db,dir."
        exit 1
        ;;
    esac
  done

  if [ "$mode_count" -eq 0 ]; then
    echo "You need to set RESTORE_MODE to db, dir, or db,dir."
    exit 1
  fi
}

cleanup() {
  if [ -n "${temp_dir:-}" ] && [ -d "$temp_dir" ]; then
    rm -rf "$temp_dir"
  fi
  if [ -n "${staging_dir:-}" ] && [ -e "$staging_dir" ]; then
    rm -rf "$staging_dir"
  fi
  if [ -n "${backup_dir:-}" ] && [ -e "$backup_dir" ] && [ "${preserve_backup_dir:-no}" != "yes" ]; then
    rm -rf "$backup_dir"
  fi
}

trap cleanup EXIT INT TERM

download_key() {
  key_suffix="$1"
  local_file="$2"

  echo "Fetching backup from S3..."
  aws $aws_args s3 cp "${s3_uri_base}/${key_suffix}" "$local_file"
}

decrypt_file() {
  encrypted_file="$1"
  output_file="$2"

  echo "Decrypting backup..."
  gpg --decrypt --batch --passphrase "$PASSPHRASE" "$encrypted_file" > "$output_file"
  rm "$encrypted_file"
}

select_latest_key() {
  prefix="$1"
  suffix="$2"

  aws $aws_args s3api list-objects-v2 \
    --bucket "$S3_BUCKET" \
    --prefix "$prefix" \
    --query "sort_by(Contents[?ends_with(Key, \`${suffix}\`)], &LastModified)[-1].Key" \
    --output text
}

restore_db() {
  if [ -z "$PASSPHRASE" ]; then
    file_type=".dump"
  else
    file_type=".dump.gpg"
  fi

  if [ $# -eq 1 ]; then
    timestamp="$1"
    key_suffix="${POSTGRES_DATABASE}_${timestamp}${file_type}"
  else
    echo "Finding latest database backup..."
    key_suffix=$(select_latest_key "${s3_uri_base}/${POSTGRES_DATABASE}" "$file_type")
  fi

  if [ -z "$key_suffix" ] || [ "$key_suffix" = "None" ]; then
    echo "No database backup found."
    exit 1
  fi

  download_key "$key_suffix" "db${file_type}"

  if [ -n "$PASSPHRASE" ]; then
    decrypt_file db.dump.gpg db.dump
  fi

  conn_opts="-h $POSTGRES_HOST -p $POSTGRES_PORT -U $POSTGRES_USER -d $POSTGRES_DATABASE"

  echo "Restoring PostgreSQL backup..."
  pg_restore $conn_opts --clean --if-exists db.dump
  rm db.dump

  echo "Database restore complete."
}

validate_tar_archive() {
  archive_file="$1"

  tar -tzf "$archive_file" | while IFS= read -r entry; do
    case "$entry" in
      ""|/*|../*|*"/../"*|*"/.."|"..")
        echo "The archive contains an unsafe path: $entry"
        exit 1
        ;;
    esac
  done
}

restore_dir() {
  if [ -z "$RESTORE_DIR" ]; then
    echo "You need to set the RESTORE_DIR environment variable when RESTORE_MODE includes dir."
    exit 1
  fi

  case "$RESTORE_DIR" in
    /*) ;;
    *)
      echo "RESTORE_DIR must be an absolute path."
      exit 1
      ;;
  esac

  if [ "$RESTORE_DIR" = "/" ]; then
    echo "RESTORE_DIR must not be /."
    exit 1
  fi

  if [ -z "$RESTORE_SOURCE_NAME" ]; then
    restore_source_name=$(basename "$RESTORE_DIR")
  else
    restore_source_name="$RESTORE_SOURCE_NAME"
  fi

  case "$restore_source_name" in
    ""|"."|"/"|*/*|"..")
      echo "RESTORE_SOURCE_NAME must be a single directory name."
      exit 1
      ;;
  esac

  if [ -z "$PASSPHRASE" ]; then
    file_type=".tar.gz"
  else
    file_type=".tar.gz.gpg"
  fi

  if [ $# -eq 1 ]; then
    timestamp="$1"
    key_suffix="dir/${restore_source_name}_${timestamp}${file_type}"
  else
    echo "Finding latest directory backup..."
    key_suffix=$(select_latest_key "${s3_uri_base}/dir/${restore_source_name}_" "$file_type")
  fi

  if [ -z "$key_suffix" ] || [ "$key_suffix" = "None" ]; then
    echo "No directory backup found."
    exit 1
  fi

  temp_dir=$(mktemp -d)
  archive_file="$temp_dir/archive${file_type}"

  staging_dir="${RESTORE_DIR}.restore-staging.$$"
  backup_dir=""
  preserve_backup_dir="no"

  download_key "$key_suffix" "$archive_file"

  if [ -n "$PASSPHRASE" ]; then
    decrypt_file "$archive_file" "$temp_dir/archive.tar.gz"
    archive_file="$temp_dir/archive.tar.gz"
  fi

  validate_tar_archive "$archive_file"

  target_parent=$(dirname "$RESTORE_DIR")
  mkdir -p "$target_parent"

  rm -rf "$staging_dir"
  mkdir -p "$staging_dir"
  tar -xzf "$archive_file" -C "$staging_dir"

  source_dir="$staging_dir/$restore_source_name"
  if [ ! -d "$source_dir" ]; then
    echo "The archive does not contain expected directory $restore_source_name."
    exit 1
  fi

  if [ -e "$RESTORE_DIR" ]; then
    if [ -n "$(find "$RESTORE_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
      if [ "$RESTORE_OVERWRITE" != "yes" ]; then
        echo "RESTORE_DIR is not empty. Set RESTORE_OVERWRITE=yes to replace its contents."
        exit 1
      fi

      backup_dir="${RESTORE_DIR}.restore-backup.$$"
      rm -rf "$backup_dir"
      preserve_backup_dir="yes"

      if ! mv "$RESTORE_DIR" "$backup_dir"; then
        echo "Failed to move the existing directory out of the way."
        preserve_backup_dir="no"
        exit 1
      fi

      if mv "$source_dir" "$RESTORE_DIR"; then
        rm -rf "$backup_dir"
        backup_dir=""
        preserve_backup_dir="no"
      else
        if rm -rf "$RESTORE_DIR" && mv "$backup_dir" "$RESTORE_DIR"; then
          backup_dir=""
          preserve_backup_dir="no"
        else
          echo "Failed to roll back the original directory. It is preserved at $backup_dir."
          exit 1
        fi

        echo "Failed to install the restored directory."
        exit 1
      fi
    else
      rmdir "$RESTORE_DIR"
      if ! mv "$source_dir" "$RESTORE_DIR"; then
        echo "Failed to install the restored directory."
        exit 1
      fi
    fi
  else
    if ! mv "$source_dir" "$RESTORE_DIR"; then
      echo "Failed to install the restored directory."
      exit 1
    fi
  fi

  echo "Directory restore complete."
}

validate_restore_mode

if [ "$#" -gt 1 ]; then
  echo "You can provide at most one timestamp."
  exit 1
fi

s3_uri_base="s3://${S3_BUCKET}/${S3_PREFIX}"

case ",$RESTORE_MODE," in
  *,dir,*)
    restore_dir "$@"
    ;;
esac

case ",$RESTORE_MODE," in
  *,db,*)
    restore_db "$@"
    ;;
esac

echo "Restore complete."
