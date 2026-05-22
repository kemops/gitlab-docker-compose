#!/usr/bin/env bash
###############################################################################
# GitLab Full Backup (Cronjob Optimized)
###############################################################################

set -euo pipefail

COMPOSE_DIR="${COMPOSE_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
CONTAINER="${CONTAINER:-gitlab}"
OUTPUT_DIR="${OUTPUT_DIR:-${COMPOSE_DIR}/archives}"
KEEP_DAYS="${KEEP_DAYS:-14}"

DATE="$(date +%Y%m%d_%H%M%S)"
mkdir -p "${OUTPUT_DIR}"

# ปรับ Log ให้สั้นและเป็นระเบียบ
log() { echo "[$(date '+%F %T')] $*"; }
die() { echo "[$(date '+%F %T')] ERROR: $*" >&2; exit 1; }

docker inspect "${CONTAINER}" >/dev/null 2>&1 \
    || die "Container '${CONTAINER}' is not running."

# ==============================================================================
# B E G I N   B A C K U P   P R O C E S S
# ==============================================================================
echo "###################################################"
log "BACKUP START: GitLab -> ${OUTPUT_DIR}"

log "TASK: Running gitlab-backup create..."
docker exec -t "${CONTAINER}" gitlab-backup create CRON=1 >/dev/null

APP_BACKUP_PATH=$(docker exec "${CONTAINER}" bash -c "ls -t /var/opt/gitlab/backups/*_gitlab_backup.tar 2>/dev/null | head -1" | tr -d '\r')
if [[ -z "${APP_BACKUP_PATH}" ]]; then
    die "Backup file not found inside container."
fi

STAGE="${OUTPUT_DIR}/.stage_${DATE}"
mkdir -p "${STAGE}"
trap 'rm -rf "${STAGE}"' EXIT

log "TASK: Extracting data & secrets..."
docker cp "${CONTAINER}:${APP_BACKUP_PATH}" "${STAGE}/"
docker cp "${CONTAINER}:/etc/gitlab/gitlab-secrets.json" "${STAGE}/"
docker cp "${CONTAINER}:/etc/gitlab/gitlab.rb" "${STAGE}/" 2>/dev/null || true
cp "${COMPOSE_DIR}/compose.yaml" "${STAGE}/" 2>/dev/null || true
cp "${COMPOSE_DIR}/.env" "${STAGE}/" 2>/dev/null || true

ARCHIVE="${OUTPUT_DIR}/gitlab_full_${DATE}.tar.gz"
tar -czf "${ARCHIVE}" -C "${STAGE}" .

SIZE="$(du -h "${ARCHIVE}" | cut -f1)"
log "SUCCESS: Archive created $(basename "${ARCHIVE}") (${SIZE})"

log "TASK: Pruning archives older than ${KEEP_DAYS} days..."
find "${OUTPUT_DIR}" -name 'gitlab_full_*.tar.gz' -mtime "+${KEEP_DAYS}" -delete

sudo chown "$(id -u):$(id -g)" "${ARCHIVE}" 2>/dev/null || true

log "BACKUP FINISHED"
echo "###################################################"