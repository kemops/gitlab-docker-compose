#!/bin/bash

# ==========================================
# CONFIGURATION
# ==========================================
# หาที่อยู่ของโฟลเดอร์โปรเจกต์แบบอัตโนมัติ
COMPOSE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_FOLDER="${COMPOSE_DIR}/archives"

DESTINATION="gdrive:db-backup/gitlab-docker-compose"

log() { echo "[$(date '+%F %T')] $*"; }

if [ ! -d "$SOURCE_FOLDER" ]; then
    log "ERROR: Directory not found at $SOURCE_FOLDER"
    exit 1
fi

log "SYNC START: Local -> GDrive"

# เอา --progress ออก เพื่อไม่ให้ log ของ cron รก
if rclone copy "$SOURCE_FOLDER" "$DESTINATION"; then
    log "SYNC SUCCESS: All files are up to date."
else
    log "SYNC ERROR: Rclone failed."
    exit 1
fi