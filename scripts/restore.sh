#!/usr/bin/env bash
###############################################################################
# GitLab Restore (Named Volumes Edition + Interactive Selection)
# Restores a GitLab instance from an archive produced by ./backup.sh
# Uses `docker cp` to inject files back into the container.
###############################################################################

set -euo pipefail

COMPOSE_DIR="${COMPOSE_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
CONTAINER="${CONTAINER:-gitlab}"
ARCHIVE_DIR="${ARCHIVE_DIR:-${COMPOSE_DIR}/archives}"

log()  { echo "[$(date '+%F %T')] $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage:
  $0                         # Interactive mode (select from list)
  $0 <archive.tar.gz>        # Restore a specific archive
  $0 --latest                # Restore the newest archive in ${ARCHIVE_DIR}
  $0 -y                      # Skip confirmation prompt (can be combined with other flags)
EOF
    exit 1
}

# ---- Parse args --------------------------------------------------------------
ASSUME_YES=0
ARCHIVE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)    ASSUME_YES=1; shift ;;
        --latest)
            ARCHIVE="$(ls -t "${ARCHIVE_DIR}"/gitlab_full_*.tar.gz 2>/dev/null | head -1 || true)"
            [[ -n "${ARCHIVE}" ]] || die "no archives found in ${ARCHIVE_DIR}"
            shift
            ;;
        -h|--help)   usage ;;
        -*)          die "unknown flag: $1" ;;
        *)           ARCHIVE="$1"; shift ;;
    esac
done

docker inspect "${CONTAINER}" >/dev/null 2>&1 \
    || die "container '${CONTAINER}' not found — run 'docker compose up -d' first"

# ---- Interactive Selection (If no archive specified) -------------------------
if [[ -z "${ARCHIVE}" ]]; then
    # โหลดรายชื่อไฟล์เข้า Array เรียงตามเวลา (ใหม่ล่าสุดอยู่บน)
    shopt -s nullglob
    mapfile -t BACKUP_FILES < <(ls -t "${ARCHIVE_DIR}"/gitlab_full_*.tar.gz 2>/dev/null)
    shopt -u nullglob

    if [[ ${#BACKUP_FILES[@]} -eq 0 ]]; then
        die "No backup archives found in ${ARCHIVE_DIR}"
    fi

    echo ""
    echo "====================================================="
    echo "  Available GitLab Backups"
    echo "====================================================="
    for i in "${!BACKUP_FILES[@]}"; do
        FILE_NAME="$(basename "${BACKUP_FILES[$i]}")"
        FILE_SIZE="$(du -h "${BACKUP_FILES[$i]}" | cut -f1)"
        printf "  %2d) %-40s (%s)\n" $((i+1)) "${FILE_NAME}" "${FILE_SIZE}"
    done
    echo "====================================================="
    echo ""

    read -rp "Enter the number to restore (1-${#BACKUP_FILES[@]}, or 'q' to quit): " choice

    if [[ "$choice" == "q" || "$choice" == "Q" ]]; then
        log "Aborted by user."
        exit 0
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#BACKUP_FILES[@]}" ]; then
        die "Invalid selection: $choice"
    fi

    ARCHIVE="${BACKUP_FILES[$((choice-1))]}"
    log "Selected archive: $(basename "${ARCHIVE}")"
fi

[[ -f "${ARCHIVE}" ]] || die "archive not found: ${ARCHIVE}"

# ---- Confirmation ------------------------------------------------------------
cat <<EOF

╔═══════════════════════════════════════════════════════════════╗
║              GitLab RESTORE — destructive action!              ║
╠═══════════════════════════════════════════════════════════════╣
║ This will OVERWRITE the current GitLab data with the archive: ║
║  $(basename "${ARCHIVE}")
╚═══════════════════════════════════════════════════════════════╝

EOF

if [[ "${ASSUME_YES}" -ne 1 ]]; then
    read -rp "Type 'yes' to continue: " ans
    [[ "${ans}" == "yes" ]] || die "aborted by user"
fi

# ---- Stage the archive -------------------------------------------------------
STAGE="${ARCHIVE_DIR}/.stage_restore_$$"
mkdir -p "${STAGE}"
trap 'rm -rf "${STAGE}"' EXIT

log "Extracting archive to ${STAGE}..."
tar -xzf "${ARCHIVE}" -C "${STAGE}"

APP_TAR="$(find "${STAGE}" -maxdepth 2 -name '*_gitlab_backup.tar' | head -1 || true)"
SECRETS="$(find "${STAGE}" -maxdepth 2 -name 'gitlab-secrets.json' | head -1 || true)"
GITLAB_RB="$(find "${STAGE}" -maxdepth 2 -name 'gitlab.rb' | head -1 || true)"

[[ -n "${APP_TAR}" ]] || die "no *_gitlab_backup.tar inside the archive"
[[ -n "${SECRETS}" ]] || die "no gitlab-secrets.json inside the archive"

APP_TAR_BASENAME="$(basename "${APP_TAR}")"
BACKUP_NAME="${APP_TAR_BASENAME%_gitlab_backup.tar}"

log "Backup identifier:  ${BACKUP_NAME}"

# ---- Stop services -----------------------------------------------------------
log "Stopping puma and sidekiq..."
docker exec "${CONTAINER}" gitlab-ctl stop puma
docker exec "${CONTAINER}" gitlab-ctl stop sidekiq

# ---- Inject secrets and app backup via docker cp ----------------------------
log "Injecting gitlab-secrets.json into container..."
docker cp "${SECRETS}" "${CONTAINER}:/etc/gitlab/gitlab-secrets.json"
docker exec "${CONTAINER}" chmod 600 /etc/gitlab/gitlab-secrets.json

if [[ -n "${GITLAB_RB}" ]]; then
    log "Injecting gitlab.rb..."
    docker cp "${GITLAB_RB}" "${CONTAINER}:/etc/gitlab/gitlab.rb"
fi

log "Injecting application backup to container..."
docker cp "${APP_TAR}" "${CONTAINER}:/var/opt/gitlab/backups/${APP_TAR_BASENAME}"
# ให้สิทธิ์ user 'git' (UID 998) ภายในคอนเทนเนอร์
docker exec "${CONTAINER}" chown 998:998 "/var/opt/gitlab/backups/${APP_TAR_BASENAME}"
docker exec "${CONTAINER}" chmod 600 "/var/opt/gitlab/backups/${APP_TAR_BASENAME}"

# ---- Run the restore --------------------------------------------------------
log "Running gitlab-backup restore (this can take several minutes)..."
docker exec -t "${CONTAINER}" gitlab-backup restore "BACKUP=${BACKUP_NAME}" force=yes

# ---- Reconfigure, restart, verify -------------------------------------------
log "Reconfiguring GitLab..."
docker exec "${CONTAINER}" gitlab-ctl reconfigure

log "Restarting all services..."
docker exec "${CONTAINER}" gitlab-ctl restart

log "Running gitlab:check (this can take a minute)..."
docker exec -t "${CONTAINER}" gitlab-rake gitlab:check SANITIZE=true || \
    log "WARNING: gitlab:check reported issues — review the output above"

log "Restore completed successfully. Please check your GitLab URL."