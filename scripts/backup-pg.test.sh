#!/usr/bin/env bash
# Regression coverage for the backup runner's child-process configuration.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$TMP/bin" "$TMP/staging" "$TMP/remote"
printf 'restic-password\n' >"$TMP/password"
printf 'gatus-token\n' >"$TMP/gatus-token"
chmod 600 "$TMP/password" "$TMP/gatus-token"

cat >"$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%2048s' dump-data
EOF
cat >"$TMP/bin/restic" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${RESTIC_REPOSITORY-}" >"$TEST_TMP/restic-repository"
cat >/dev/null
EOF
cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/bin/"*

export PATH="$TMP/bin:$PATH"
export TEST_TMP="$TMP"
export BACKUP_PG_REMOTE_DIR="$TMP/remote"
export BACKUP_PG_STAGING_DIR="$TMP/staging"
export BACKUP_PG_PASSWORD_FILE="$TMP/password"
export BACKUP_PG_GATUS_TOKEN_FILE="$TMP/gatus-token"
export BACKUP_PG_REPOSITORY='rclone:test:repo'
export BACKUP_PG_MIN_DUMP_BYTES=1
export BACKUP_PG_PREVIOUS_SIZE_FILE="$TMP/previous-size"
export BACKUP_PG_LOCK_FILE="$TMP/backup.lock"
export BACKUP_PG_RESTIC_BIN=restic

bash "$ROOT/scripts/backup-pg.sh" run

actual="$(<"$TMP/restic-repository")"
[[ "$actual" == "$BACKUP_PG_REPOSITORY" ]] || fail "restic child received repository '$actual', want '$BACKUP_PG_REPOSITORY'"
echo "backup repository propagation test passed"
