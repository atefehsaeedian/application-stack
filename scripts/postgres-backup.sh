#!/bin/bash

set -euo pipefail

BACKUP_DIR="/opt/backups/postgres"
CONTAINER="application-stack-postgres-1"
DB_NAME="appdb"
DB_USER="appuser"
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
BACKUP_FILE="${BACKUP_DIR}/${DB_NAME}_${TIMESTAMP}.sql.gz"

mkdir -p "$BACKUP_DIR"

echo "Starting PostgreSQL backup: $BACKUP_FILE"

docker exec "$CONTAINER" \
    pg_dump -U "$DB_USER" -d "$DB_NAME" \
    | gzip > "$BACKUP_FILE"

if [[ ! -s "$BACKUP_FILE" ]]; then
    echo "ERROR: Backup file is empty: $BACKUP_FILE" >&2
    rm -f "$BACKUP_FILE"
    exit 1
fi

find "$BACKUP_DIR" \
    -type f \
    -name "${DB_NAME}_*.sql.gz" \
    -mtime +7 \
    -delete

echo "Backup completed successfully: $BACKUP_FILE"
