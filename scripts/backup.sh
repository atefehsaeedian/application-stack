#!/bin/bash

set -Eeuo pipefail

# ============================================================
# Configuration
# ============================================================

BACKUP_ROOT="/opt/backups/application-stack"
LOG_DIR="$HOME/.local/state/app-backup"
LOG_FILE="$LOG_DIR/backup.log"
LOCK_FILE="/tmp/application-stack-backup.lock"

POSTGRES_CONTAINER="application-stack-postgres-1"
DB_NAME="appdb"
DB_USER="appuser"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RETENTION_COUNT=7

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
BACKUP_NAME="application-stack_${TIMESTAMP}"
WORK_DIR="${BACKUP_ROOT}/${BACKUP_NAME}"
ARCHIVE="${BACKUP_ROOT}/${BACKUP_NAME}.tar.gz"


# ============================================================
# Setup
# ============================================================

mkdir -p "$BACKUP_ROOT"
mkdir -p "$LOG_DIR"

exec > >(tee -a "$LOG_FILE") 2>&1


# ============================================================
# Logging
# ============================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}


fail() {
    log "ERROR: $*"
    exit 1
}


# ============================================================
# Cleanup
# ============================================================

cleanup() {
    rm -rf "$WORK_DIR"
}

trap cleanup EXIT


# ============================================================
# Lock
# ============================================================

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    fail "Another backup process is already running"
fi


# ============================================================
# Required Commands
# ============================================================

for command in docker tar gzip find flock tee; do
    if ! command -v "$command" >/dev/null 2>&1; then
        fail "Required command not found: $command"
    fi
done


# ============================================================
# Start
# ============================================================

log "========================================"
log "Starting application backup"
log "Backup: $BACKUP_NAME"
log "========================================"


# ============================================================
# Validate PostgreSQL
# ============================================================

log "Checking PostgreSQL container"

if ! sudo docker inspect "$POSTGRES_CONTAINER" >/dev/null 2>&1; then
    fail "PostgreSQL container not found: $POSTGRES_CONTAINER"
fi

POSTGRES_STATUS="$(
    sudo docker inspect \
        -f '{{.State.Status}}' \
        "$POSTGRES_CONTAINER"
)"

if [[ "$POSTGRES_STATUS" != "running" ]]; then
    fail "PostgreSQL container is not running"
fi

log "PostgreSQL container is running"


# ============================================================
# Validate Configuration
# ============================================================

log "Checking configuration files"

[[ -f "$REPO_DIR/docker/compose.yaml" ]] ||
    fail "Missing Docker Compose configuration"

[[ -f "$REPO_DIR/.env.example" ]] ||
    fail "Missing .env.example"

[[ -f "/opt/nginx/nginx.conf" ]] ||
    fail "Missing Nginx configuration"

[[ -d "/opt/nginx/tls" ]] ||
    fail "Missing Nginx TLS directory"


# ============================================================
# Create Backup Structure
# ============================================================

mkdir -p "$WORK_DIR/postgres"
mkdir -p "$WORK_DIR/nginx"
mkdir -p "$WORK_DIR/application"


# ============================================================
# PostgreSQL Backup
# ============================================================

log "Creating PostgreSQL dump"

if ! sudo docker exec \
    "$POSTGRES_CONTAINER" \
    pg_dump \
    -U "$DB_USER" \
    -d "$DB_NAME" \
    > "$WORK_DIR/postgres/${DB_NAME}.sql"
then
    fail "PostgreSQL dump failed"
fi


if [[ ! -s "$WORK_DIR/postgres/${DB_NAME}.sql" ]]; then
    fail "PostgreSQL dump is empty"
fi

log "PostgreSQL dump completed"


# ============================================================
# Nginx Configuration Backup
# ============================================================

log "Backing up Nginx configuration"

cp "/opt/nginx/nginx.conf" \
    "$WORK_DIR/nginx/nginx.conf"

cp -a "/opt/nginx/tls" \
    "$WORK_DIR/nginx/tls"


# ============================================================
# Application Configuration Backup
# ============================================================

log "Backing up application configuration"

cp "$REPO_DIR/.env.example" \
    "$WORK_DIR/application/.env.example"

cp "$REPO_DIR/docker/compose.yaml" \
    "$WORK_DIR/application/compose.yaml"

cp -a "$REPO_DIR/docker" \
    "$WORK_DIR/application/docker"

cp -a "$REPO_DIR/systemd" \
    "$WORK_DIR/application/systemd"

cp -a "$REPO_DIR/scripts" \
    "$WORK_DIR/application/scripts"

cp "$REPO_DIR/README.md" \
    "$WORK_DIR/application/README.md"


# ============================================================
# Verify Backup Contents
# ============================================================

log "Verifying backup contents"

[[ -s "$WORK_DIR/postgres/${DB_NAME}.sql" ]] ||
    fail "PostgreSQL backup verification failed"

[[ -s "$WORK_DIR/nginx/nginx.conf" ]] ||
    fail "Nginx configuration backup verification failed"

[[ -s "$WORK_DIR/application/compose.yaml" ]] ||
    fail "Application configuration backup verification failed"

[[ -s "$WORK_DIR/application/.env.example" ]] ||
    fail "Application environment template backup verification failed"


# ============================================================
# Create Compressed Archive
# ============================================================

log "Creating compressed archive"

tar -czf "$ARCHIVE" \
    -C "$BACKUP_ROOT" \
    "$BACKUP_NAME"


# ============================================================
# Verify Archive
# ============================================================

if [[ ! -s "$ARCHIVE" ]]; then
    fail "Backup archive was not created"
fi

if ! tar -tzf "$ARCHIVE" >/dev/null 2>&1; then
    fail "Backup archive validation failed"
fi

log "Backup archive verified: $ARCHIVE"


# ============================================================
# Remove Old Backups
# ============================================================

log "Applying retention policy"

mapfile -t BACKUPS < <(
    find "$BACKUP_ROOT" \
        -maxdepth 1 \
        -type f \
        -name 'application-stack_*.tar.gz' \
        -printf '%T@ %p\n' |
    sort -nr |
    awk '{print $2}'
)

if (( ${#BACKUPS[@]} > RETENTION_COUNT )); then

    for ((i=RETENTION_COUNT; i<${#BACKUPS[@]}; i++)); do
        log "Removing old backup: ${BACKUPS[$i]}"
        rm -f "${BACKUPS[$i]}"
    done

fi


# ============================================================
# Final Validation
# ============================================================

if [[ ! -s "$ARCHIVE" ]]; then
    fail "Final backup validation failed"
fi

BACKUP_SIZE="$(du -h "$ARCHIVE" | awk '{print $1}')"

log "Backup size: $BACKUP_SIZE"
log "Retention count: $RETENTION_COUNT"
log "Backup completed successfully"
log "Archive: $ARCHIVE"

exit 0
