#!/bin/bash
set -euo pipefail

# Source environment variables (cron does not inherit them)
if [ -f /etc/environment.backup ]; then
  set -a
  source /etc/environment.backup
  set +a
fi

TODAY=$(date +%Y-%m-%d)
LOG_PREFIX="[backup][${TODAY}]"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-neo4j}"
NEO4J_SERVICE="${NEO4J_SERVICE:-neo4j}"
if [ -n "${BACKUP_NEO4J_CONTAINER:-}" ]; then
  CONTAINER="${BACKUP_NEO4J_CONTAINER}"
else
  # Auto-discover: find a running container whose name starts with the service
  # name but is NOT the backup container
  CONTAINER=$(docker ps --format '{{.Names}}' | grep "^${NEO4J_SERVICE}" | grep -v backup | head -1)
  if [ -z "${CONTAINER}" ]; then
    CONTAINER="${COMPOSE_PROJECT}-${NEO4J_SERVICE}-1"
  fi
fi
DATA_DIR="/data"
BACKUP_DIR="/backups/${TODAY}"
HOST_DATA_DIR="${HOST_DATA_DIR:-}"
HOST_BACKUP_DIR="${HOST_BACKUP_DIR:-}"
S3_BUCKET="${S3_BUCKET:-}"
S3_ENDPOINT="${S3_ENDPOINT:-}"
DUMP_FAILED=0
LOCK_FILE="/tmp/backup.lock"

log() { echo "${LOG_PREFIX} $(date +%H:%M:%S) $*"; }

# --- Phase 0: Pre-flight checks ---
if [ -z "${HOST_DATA_DIR}" ]; then
  log "Backup not configured (HOST_DATA_DIR not set). Skipping."
  exit 0
fi

if [ -z "${HOST_BACKUP_DIR}" ]; then
  log "Backup not configured (HOST_BACKUP_DIR not set). Skipping."
  exit 0
fi

log "=== Starting backup ==="
log "Host data dir: ${HOST_DATA_DIR}"
log "Host backup dir: ${HOST_BACKUP_DIR}"

# --- Phase 1: Discover databases ---
DATABASES=()
for dir in "${DATA_DIR}/databases"/*/; do
  [ -d "$dir" ] || continue
  dbname=$(basename "$dir")
  # Skip hidden directories
  [[ "$dbname" == .* ]] && continue
  DATABASES+=("$dbname")
done

log "Discovered ${#DATABASES[@]} databases: ${DATABASES[*]}"

if [ ${#DATABASES[@]} -eq 0 ]; then
  log "ERROR: No databases found in ${DATA_DIR}/databases/. Aborting."
  exit 1
fi

# --- Phase 2: Stop Neo4j ---
# Lock file prevents the watchdog from restarting Neo4j mid-backup
touch "${LOCK_FILE}"
trap 'rm -f "${LOCK_FILE}"' EXIT

log "Stopping Neo4j container (${CONTAINER})..."
if ! docker update --restart=no "${CONTAINER}" 2>/dev/null || ! docker stop "${CONTAINER}" 2>/dev/null; then
  # Try underscore naming convention (Compose v1)
  ALT_CONTAINER="${COMPOSE_PROJECT}_${NEO4J_SERVICE}_1"
  log "Trying alternative container name: ${ALT_CONTAINER}"
  if ! docker update --restart=no "${ALT_CONTAINER}" 2>/dev/null || ! docker stop "${ALT_CONTAINER}" 2>/dev/null; then
    log "ERROR: Could not stop Neo4j container. Aborting."
    exit 1
  fi
  CONTAINER="${ALT_CONTAINER}"
fi
log "Neo4j stopped."

# --- Phase 3: Dump each database ---
mkdir -p "${BACKUP_DIR}"

for db in "${DATABASES[@]}"; do
  log "Dumping database: ${db}..."
  if docker run --rm \
    -v "${HOST_DATA_DIR}:/data" \
    -v "${HOST_BACKUP_DIR}/${TODAY}:/backups" \
    neo4j/neo4j-admin:5.26-community-bullseye \
    neo4j-admin database dump "${db}" --to-path=/backups --overwrite-destination=true 2>&1; then
    log "  OK: ${db}"
  else
    log "  FAILED: ${db}"
    DUMP_FAILED=1
  fi
done

# --- Phase 4: Restart Neo4j (ALWAYS, even if dumps failed) ---
log "Starting Neo4j container (${CONTAINER})..."
if ! docker start "${CONTAINER}" 2>/dev/null; then
  log "CRITICAL: Could not restart Neo4j container!"
fi
docker update --restart=always "${CONTAINER}" 2>/dev/null || true
log "Neo4j restarted."

# --- Phase 5: Upload to S3 ---
if [ -n "${S3_BUCKET}" ] && [ -n "${S3_ENDPOINT}" ]; then
  log "Uploading to S3: s3://${S3_BUCKET}/${TODAY}/"
  if aws s3 cp "${BACKUP_DIR}/" "s3://${S3_BUCKET}/${TODAY}/" \
    --recursive \
    --endpoint-url "${S3_ENDPOINT}" \
    --no-progress 2>&1; then
    log "S3 upload complete."
  else
    log "WARNING: S3 upload failed."
  fi
fi

# --- Phase 6: Apply retention ---
/usr/local/bin/retention.sh

log "=== Backup complete (dump failures: ${DUMP_FAILED}) ==="
exit ${DUMP_FAILED}
