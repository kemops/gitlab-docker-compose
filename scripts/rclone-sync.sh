#!/bin/bash

# ==========================================
# CONFIGURATION
# ==========================================
COMPOSE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_FOLDER="${COMPOSE_DIR}/archives"

DESTINATION="gdrive:db-backup/gitlab-docker-compose"

log() { echo "[$(date '+%F %T')] $*"; }

if [ ! -d "$SOURCE_FOLDER" ]; then
    log "ERROR: Directory not found at $SOURCE_FOLDER"
    exit 1
fi

# ==============================================================================
# B E G I N   S Y N C   P R O C E S S
# ==============================================================================
echo "###################################################"
log "SYNC START: Local -> GDrive"

# เอา --progress ออก เพื่อไม่ให้ log ของ cron รก
log "TASK: Running rclone copy..."
if rclone copy "$SOURCE_FOLDER" "$DESTINATION"; then
    log "SUCCESS: All files are up to date."
else
    log "ERROR: Rclone failed."
    echo "###################################################"
    exit 1
fi

log "SYNC FINISHED"
echo "###################################################"