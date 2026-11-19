#!/usr/bin/env bash
# HOMEINFRA-787: nightly Postgres dump to the off-host restic repository.
# Installed in root's crontab by remote-bootstrap.sh at 03:00 UTC.
# Credentials are root-only files populated from Infisical home-edge/prod /backup/.
set -euo pipefail

CONFIG=${BACKUP_PG_CONFIG:-/etc/inngest/backup-pg.env}
if [[ -f $CONFIG ]]; then
  set -a
  # shellcheck source=/dev/null
  . "$CONFIG"
  set +a
fi

REMOTE_DIR=${BACKUP_PG_REMOTE_DIR:-/opt/inngest}
BACKUP_DIR=${BACKUP_PG_STAGING_DIR:-$REMOTE_DIR/backups}
BACKUP_DIR=${BACKUP_DIR%/}
PASSWORD_FILE=${BACKUP_PG_PASSWORD_FILE:-/etc/inngest/backup/restic-password}
SA_FILE=${BACKUP_PG_SA_FILE:-/etc/inngest/backup/gdrive-sa.json}
GATUS_TOKEN_FILE=${BACKUP_PG_GATUS_TOKEN_FILE:-/etc/inngest/backup/gatus-token}
GATUS_URL=${BACKUP_PG_GATUS_URL:-https://status.practical.works/api/v1/endpoints/home-infra_inngest-backup/external}
SHARED_DRIVE_ID=${BACKUP_PG_GDRIVE_SHARED_DRIVE_ID:-}
REPO_PATH=${BACKUP_PG_REPO_PATH:-restic/inngest}
RESTIC_REPOSITORY=${BACKUP_PG_REPOSITORY:-rclone:inngestgdrive:$REPO_PATH}
RESTIC_BIN=${BACKUP_PG_RESTIC_BIN:-restic}
RCLONE_CONFIG=${BACKUP_PG_RCLONE_CONFIG:-/etc/inngest/backup/rclone.conf}
MIN_DUMP_BYTES=${BACKUP_PG_MIN_DUMP_BYTES:-1024}
PREVIOUS_SIZE_FILE=${BACKUP_PG_PREVIOUS_SIZE_FILE:-$BACKUP_DIR/.previous-size}
LOCK_FILE=${BACKUP_PG_LOCK_FILE:-/run/lock/inngest-pg-backup.lock}

log() { printf 'inngest-pg-backup: %s\n' "$*" >&2; }

check_secret_file() {
  local file=$1 name=$2 mode
  if [[ ! -s $file ]]; then
    echo "missing credential $file (Infisical home-edge/prod /backup/$name)"
    return 1
  fi
  mode=$(stat -c %a "$file")
  if [[ ! -O $file || ( $mode != 600 && $mode != 400 ) ]]; then
    echo "credential $file must be owned by $(id -un) with mode 0600 (is $mode)"
    return 1
  fi
}

heartbeat() {
  local ok=$1 error=${2:-} token
  if ! check_secret_file "$GATUS_TOKEN_FILE" GATUS_INNGEST_BACKUP_TOKEN; then
    log "heartbeat credential unavailable; success=$ok was not reported"
    return 1
  fi
  token=$(<"$GATUS_TOKEN_FILE")
  token=${token//[[:space:]]/}
  curl -fsS -m 30 -o /dev/null -X POST -G \
    --data-urlencode "success=$ok" --data-urlencode "error=$error" \
    -H @<(printf 'Authorization: Bearer %s\n' "$token") "$GATUS_URL"
  log "reported success=$ok to Gatus"
}

fail_run() {
  local message=$1
  log "$message"
  heartbeat false "$message" || log "could not report failure heartbeat"
  exit 1
}

check_config() {
  check_secret_file "$PASSWORD_FILE" INNGEST_BACKUP_RESTIC_PASSWORD || return 1
  check_secret_file "$GATUS_TOKEN_FILE" GATUS_INNGEST_BACKUP_TOKEN || return 1
  if [[ -z ${BACKUP_PG_REPOSITORY:-} ]]; then
    [[ -n $SHARED_DRIVE_ID && $SHARED_DRIVE_ID != CHANGE_ME* ]] || { echo "BACKUP_PG_GDRIVE_SHARED_DRIVE_ID is unset"; return 1; }
    check_secret_file "$SA_FILE" INNGEST_BACKUP_GDRIVE_SA_JSON || return 1
  else
    [[ -n $RESTIC_REPOSITORY ]] || { echo "BACKUP_PG_REPOSITORY is empty"; return 1; }
  fi
  [[ $MIN_DUMP_BYTES =~ ^[1-9][0-9]*$ ]] || { echo "MIN_DUMP_BYTES must be positive"; return 1; }
}

run_backup() {
  local stamp file size previous
  cd "$REMOTE_DIR"
  stamp=$(date +%Y%m%d-%H%M%S)
  mkdir -p "$BACKUP_DIR"
  file=$(mktemp "$BACKUP_DIR/.inngest-${stamp}.XXXXXX.sql.gz")
  trap 'rm -f "${file:-}"' EXIT

  log "dumping Postgres"
  if ! docker compose exec -T postgres pg_dump -U inngest inngest | gzip >"$file"; then
    fail_run "pg_dump failed"
  fi
  size=$(stat -c %s "$file")
  (( size >= MIN_DUMP_BYTES )) || fail_run "dump size ${size} bytes is below absolute floor ${MIN_DUMP_BYTES}"
  if [[ -s $PREVIOUS_SIZE_FILE ]]; then
    previous=$(<"$PREVIOUS_SIZE_FILE")
    [[ $previous =~ ^[1-9][0-9]*$ ]] || fail_run "previous dump size is invalid"
    (( size * 2 >= previous )) || fail_run "dump size ${size} bytes is below 50% of previous ${previous} bytes"
  fi

  export RESTIC_PASSWORD_FILE=$PASSWORD_FILE
  if [[ -z ${BACKUP_PG_REPOSITORY:-} ]]; then
    export RCLONE_CONFIG_INNGESTGDRIVE_TYPE=drive
    export RCLONE_CONFIG_INNGESTGDRIVE_SCOPE=drive
    export RCLONE_CONFIG_INNGESTGDRIVE_SERVICE_ACCOUNT_FILE=$SA_FILE
    export RCLONE_CONFIG_INNGESTGDRIVE_TEAM_DRIVE=$SHARED_DRIVE_ID
  else
    export RCLONE_CONFIG="$RCLONE_CONFIG"
  fi
  log "uploading ${size} bytes to ${RESTIC_REPOSITORY}"
  "$RESTIC_BIN" backup --stdin --stdin-filename "inngest.sql.gz" \
    --tag app=inngest --tag kind=postgres <"$file" || fail_run "restic upload failed"
  printf '%s\n' "$size" >"$PREVIOUS_SIZE_FILE"
  heartbeat true ""
  log "backup complete (${size} bytes)"
}

main() {
  exec 9>"$LOCK_FILE"
  flock -n 9 || fail_run "another backup is already running"
  check_config || fail_run "configuration check failed"
  run_backup
}

case ${1:-run} in
  check-config) check_config ;;
  run) main ;;
  *) echo "usage: $0 [run|check-config]" >&2; exit 2 ;;
esac
