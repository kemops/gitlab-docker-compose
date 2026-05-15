#!/usr/bin/env bash
###############################################################################
# GitLab Full Backup (Named Volumes Edition)
# - Runs `gitlab-backup create` inside the container
# - Uses `docker cp` to pull secrets and backup files OUT of the container
# - Bundles everything into one timestamped tarball
# - Prunes archives older than $KEEP_DAYS
###############################################################################

set -euo pipefail

COMPOSE_DIR="${COMPOSE_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
CONTAINER="${CONTAINER:-gitlab}"
OUTPUT_DIR="${OUTPUT_DIR:-${COMPOSE_DIR}/archives}"
KEEP_DAYS="${KEEP_DAYS:-14}"

DATE="$(date +%Y%m%d_%H%M%S)"
mkdir -p "${OUTPUT_DIR}"

log() { echo "[$(date '+%F %T')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

docker inspect "${CONTAINER}" >/dev/null 2>&1 \
    || die "container '${CONTAINER}' not running. Start it with: docker compose up -d"

log "Starting GitLab backup (Docker CP Method)"
log "  Archive output dir: ${OUTPUT_DIR}"

# 1. Application data (สร้างไฟล์ Backup ใน Container)
log "Running gitlab-backup create..."
docker exec -t "${CONTAINER}" gitlab-backup create CRON=1

# 2. หาชื่อไฟล์ Backup ล่าสุด "ภายใน" Container
APP_BACKUP_PATH=$(docker exec "${CONTAINER}" bash -c "ls -t /var/opt/gitlab/backups/*_gitlab_backup.tar 2>/dev/null | head -1" | tr -d '\r')
if [[ -z "${APP_BACKUP_PATH}" ]]; then
    die "no *_gitlab_backup.tar found inside container's /var/opt/gitlab/backups"
fi
log "Latest application backup found: $(basename "${APP_BACKUP_PATH}")"

# 3. เตรียมโฟลเดอร์ชั่วคราว (ใช้ในโฟลเดอร์ archives เพื่อป้องกัน /tmp เต็ม)
STAGE="${OUTPUT_DIR}/.stage_${DATE}"
mkdir -p "${STAGE}"
trap 'rm -rf "${STAGE}"' EXIT

log "Copying files out of container..."
# ดูดไฟล์จาก Container ออกมาวางพักไว้ใน STAGE
docker cp "${CONTAINER}:${APP_BACKUP_PATH}" "${STAGE}/"
docker cp "${CONTAINER}:/etc/gitlab/gitlab-secrets.json" "${STAGE}/"
docker cp "${CONTAINER}:/etc/gitlab/gitlab.rb" "${STAGE}/" 2>/dev/null || true

cp "${COMPOSE_DIR}/compose.yaml" "${STAGE}/" 2>/dev/null || true
cp "${COMPOSE_DIR}/.env" "${STAGE}/" 2>/dev/null || true

# 4. รวมเป็นไฟล์ Tarball เดียวกัน
ARCHIVE="${OUTPUT_DIR}/gitlab_full_${DATE}.tar.gz"
log "Creating ${ARCHIVE}..."
tar -czf "${ARCHIVE}" -C "${STAGE}" .

SIZE="$(du -h "${ARCHIVE}" | cut -f1)"
log "Archive created: $(basename "${ARCHIVE}") (${SIZE})"

# 5. ลบไฟล์เก่า
log "Pruning archives older than ${KEEP_DAYS} days..."
find "${OUTPUT_DIR}" -name 'gitlab_full_*.tar.gz' -mtime "+${KEEP_DAYS}" -print -delete

# ให้สิทธิ์กลับมาเป็นของ user ปัจจุบัน เผื่อรันด้วย sudo หลุดมา
sudo chown "$(id -u):$(id -g)" "${ARCHIVE}" 2>/dev/null || true

log "Backup completed successfully."