#!/bin/bash
set -euo pipefail

# Source environment variables (cron does not inherit them)
if [ -f /etc/environment.backup ]; then
  set -a
  source /etc/environment.backup
  set +a
fi

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${LIB_DIR}/lib.sh"

COMPOSE_PROJECT="${COMPOSE_PROJECT:-neo4j}"
NEO4J_SERVICE="${NEO4J_SERVICE:-neo4j}"
if [ -n "${BACKUP_NEO4J_CONTAINER:-}" ]; then
  CONTAINER="${BACKUP_NEO4J_CONTAINER}"
else
  CONTAINER=$(docker ps --format '{{.Names}}' | grep "^${NEO4J_SERVICE}" | grep -v backup | head -1)
  if [ -z "${CONTAINER}" ]; then
    CONTAINER="${COMPOSE_PROJECT}-${NEO4J_SERVICE}-1"
  fi
fi
HOST_DATA_DIR="${HOST_DATA_DIR:-}"
HOST_BACKUP_DIR="${HOST_BACKUP_DIR:-}"
S3_BUCKET="${S3_BUCKET:-}"
S3_ENDPOINT="${S3_ENDPOINT:-}"
LOCK_FILE="/tmp/backup.lock"

log() { echo "[restore] $(date '+%Y-%m-%d %H:%M:%S') $*"; }

usage() {
  echo "Usage: restore.sh <backup-date> [database]"
  echo ""
  echo "  backup-date   Date of the backup to restore (YYYY-MM-DD)"
  echo "  database      Database name to restore (default: all databases in the backup)"
  echo ""
  echo "Examples:"
  echo "  restore.sh 2026-03-01          # restore all databases from March 1st"
  echo "  restore.sh 2026-03-01 neo4j    # restore only the neo4j database"
  echo ""
  echo "If the backup is not found locally, it will be downloaded from S3 (if configured)."
  exit 1
}

# --- Parse arguments ---
if [ $# -lt 1 ]; then
  usage
fi

BACKUP_DATE="$1"
TARGET_DB="${2:-}"
BACKUP_DIR="/backups/${BACKUP_DATE}"

# Validate date format
if ! echo "${BACKUP_DATE}" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
  log "ERROR: Invalid date format '${BACKUP_DATE}'. Use YYYY-MM-DD."
  exit 1
fi

# --- Pre-flight checks ---
if [ -z "${HOST_DATA_DIR}" ]; then
  log "ERROR: HOST_DATA_DIR not set. Cannot restore."
  exit 1
fi

if [ -z "${HOST_BACKUP_DIR}" ]; then
  log "ERROR: HOST_BACKUP_DIR not set. Cannot restore."
  exit 1
fi

# --- Decide source: local files vs streaming from S3 ---
STREAM_FROM_S3=0
if [ ! -d "${BACKUP_DIR}" ] || [ -z "$(ls -A "${BACKUP_DIR}" 2>/dev/null)" ]; then
  if s3_configured; then
    log "Backup not found locally. Will stream from S3."
    STREAM_FROM_S3=1
  else
    log "ERROR: Backup not found at ${BACKUP_DIR} and S3 not configured."
    exit 1
  fi
fi

# --- Determine which databases to restore ---
DATABASES=()
if [ -n "${TARGET_DB}" ]; then
  DATABASES+=("${TARGET_DB}")
elif [ "${STREAM_FROM_S3}" -eq 1 ]; then
  while IFS= read -r dbname; do
    [ -n "${dbname}" ] && DATABASES+=("${dbname}")
  done < <(list_s3_databases "${BACKUP_DATE}")
else
  for dump in "${BACKUP_DIR}"/*.dump; do
    [ -f "$dump" ] || continue
    DATABASES+=("$(basename "$dump" .dump)")
  done
fi

if [ ${#DATABASES[@]} -eq 0 ]; then
  log "ERROR: No databases found for ${BACKUP_DATE} (local or S3)."
  exit 1
fi

log "=== Starting restore ==="
log "Backup date: ${BACKUP_DATE}"
log "Databases to restore: ${DATABASES[*]}"

# --- Confirmation ---
echo ""
echo "WARNING: This will stop Neo4j and overwrite the following databases:"
for db in "${DATABASES[@]}"; do
  echo "  - ${db}"
done
echo ""
read -p "Continue? [y/N] " -r REPLY
if [[ ! "${REPLY}" =~ ^[Yy]$ ]]; then
  log "Aborted by user."
  exit 0
fi

# --- Stop Neo4j ---
touch "${LOCK_FILE}"
trap 'rm -f "${LOCK_FILE}"; log "Restarting Neo4j..."; docker start "${CONTAINER}" 2>/dev/null || true; docker update --restart=always "${CONTAINER}" 2>/dev/null || true' EXIT

log "Stopping Neo4j container (${CONTAINER})..."
if ! docker update --restart=no "${CONTAINER}" 2>/dev/null || ! docker stop "${CONTAINER}" 2>/dev/null; then
  ALT_CONTAINER="${COMPOSE_PROJECT}_${NEO4J_SERVICE}_1"
  log "Trying alternative container name: ${ALT_CONTAINER}"
  if ! docker update --restart=no "${ALT_CONTAINER}" 2>/dev/null || ! docker stop "${ALT_CONTAINER}" 2>/dev/null; then
    log "ERROR: Could not stop Neo4j container. Aborting."
    exit 1
  fi
  CONTAINER="${ALT_CONTAINER}"
fi
log "Neo4j stopped."

# --- Load each database ---
LOAD_FAILED=0
for db in "${DATABASES[@]}"; do
  log "Loading database: ${db}..."
  if [ "${STREAM_FROM_S3}" -eq 1 ]; then
    if stream_load_from_s3 "${db}" "${BACKUP_DATE}"; then
      log "  OK: ${db} (streamed from S3)"
    else
      log "  FAILED: ${db}"
      LOAD_FAILED=1
    fi
  else
    if docker run --rm \
      -v "${HOST_DATA_DIR}:/data" \
      -v "${HOST_BACKUP_DIR}/${BACKUP_DATE}:/backups" \
      "${NEO4J_ADMIN_IMAGE}" \
      neo4j-admin database load "${db}" --from-path=/backups --overwrite-destination=true 2>&1; then
      log "  OK: ${db}"
    else
      log "  FAILED: ${db}"
      LOAD_FAILED=1
    fi
  fi
done

# --- Fix ownership (load creates files as root) ---
log "Starting Neo4j to fix ownership..."
docker start "${CONTAINER}" 2>/dev/null
sleep 5
for db in "${DATABASES[@]}"; do
  docker exec "${CONTAINER}" chown -R neo4j:neo4j "/data/databases/${db}" 2>/dev/null || true
  docker exec "${CONTAINER}" chown -R neo4j:neo4j "/data/transactions/${db}" 2>/dev/null || true
done
docker stop "${CONTAINER}" 2>/dev/null

# The EXIT trap will restart Neo4j with restart=always
log "=== Restore complete (load failures: ${LOAD_FAILED}) ==="
exit ${LOAD_FAILED}
