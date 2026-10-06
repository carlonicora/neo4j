#!/bin/bash
set -euo pipefail

# Nightly backup through the hot backup plugin: Neo4j keeps running.
# The plugin's backup.all() writes one .dump per database into /var/lib/neo4j/backups
# inside the Neo4j container, which is the same host folder mounted here as /backups.
# This script then files each dump by date (local mode) or uploads it to S3 (S3 mode).

# Source environment variables (cron does not inherit them)
if [ -f /etc/environment.backup ]; then
  set -a
  source /etc/environment.backup
  set +a
fi

# Load shared library (resolve dir so manual invocation also works)
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${LIB_DIR}/lib.sh"

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
BACKUP_ROOT="${BACKUP_ROOT:-/backups}"
HOST_BACKUP_DIR="${HOST_BACKUP_DIR:-}"
S3_BUCKET="${S3_BUCKET:-}"
S3_ENDPOINT="${S3_ENDPOINT:-}"
NEO4J_AUTH="${NEO4J_AUTH:-}"
DUMP_FAILED=0

log() { echo "${LOG_PREFIX} $(date +%H:%M:%S) $*"; }

# --- Phase 0: Pre-flight checks ---
if ! s3_configured && [ -z "${HOST_BACKUP_DIR}" ]; then
  log "Backup not configured (HOST_BACKUP_DIR not set and no S3). Skipping."
  exit 0
fi

if [ -z "${NEO4J_AUTH}" ]; then
  log "ERROR: NEO4J_AUTH not set. The backup procedures need admin credentials. Aborting."
  exit 1
fi

if [ ! -d "${BACKUP_ROOT}" ]; then
  log "ERROR: ${BACKUP_ROOT} is not mounted. Aborting."
  exit 1
fi

NEO4J_USER="${NEO4J_AUTH%%/*}"
NEO4J_PASSWORD="${NEO4J_AUTH#*/}"

log "=== Starting hot backup (Neo4j stays online) ==="
if s3_configured; then log "S3 configured: dumps go to s3://${S3_BUCKET}/${TODAY}/"; else log "Local mode: dumps go to ${BACKUP_ROOT}/${TODAY}/"; fi

# --- Phase 1: Run backup.all() inside the Neo4j container ---
# One row per database: "database|path|bytes|status". Any status other than "ok" is a failure.
BACKUP_QUERY="CALL backup.all() YIELD database, path, bytes, status RETURN database + '|' + coalesce(path, '') + '|' + coalesce(toString(bytes), '') + '|' + status AS row"

run_backup_all() {
  docker exec "$1" cypher-shell -u "${NEO4J_USER}" -p "${NEO4J_PASSWORD}" -d neo4j --format plain "${BACKUP_QUERY}"
}

log "Running backup.all() in ${CONTAINER}..."
if ! ROWS=$(run_backup_all "${CONTAINER}" 2>&1); then
  # Try underscore naming convention (Compose v1)
  ALT_CONTAINER="${COMPOSE_PROJECT}_${NEO4J_SERVICE}_1"
  log "Trying alternative container name: ${ALT_CONTAINER}"
  if ! ROWS=$(run_backup_all "${ALT_CONTAINER}" 2>&1); then
    log "ERROR: backup.all() failed: ${ROWS}"
    exit 1
  fi
  CONTAINER="${ALT_CONTAINER}"
fi

# --- Phase 2: File or upload each dump ---
COUNT=0
while IFS='|' read -r db path bytes status; do
  [ -n "${db}" ] || continue
  COUNT=$((COUNT + 1))

  if [ "${status}" != "ok" ]; then
    log "  FAILED: ${db} (${status})"
    DUMP_FAILED=1
    continue
  fi

  file="${BACKUP_ROOT}/$(basename "${path}")"
  if [ ! -f "${file}" ]; then
    log "  FAILED: ${db}: plugin wrote ${path} but it is not visible at ${file}. Is ./data-backup mounted at /var/lib/neo4j/backups on the neo4j service?"
    DUMP_FAILED=1
    continue
  fi

  if s3_configured; then
    if upload_dump_to_s3 "${file}" "${db}" "${TODAY}"; then
      rm -f "${file}"
      log "  OK: ${db} (${bytes} bytes, uploaded)"
    else
      # Keep the dump locally under today's date; retention.sh drains it to S3 on the next run.
      mkdir -p "${BACKUP_ROOT}/${TODAY}"
      mv -f "${file}" "${BACKUP_ROOT}/${TODAY}/${db}.dump"
      log "  FAILED: ${db}: upload failed, dump kept at ${BACKUP_ROOT}/${TODAY}/${db}.dump for retry"
      DUMP_FAILED=1
    fi
  else
    mkdir -p "${BACKUP_ROOT}/${TODAY}"
    mv -f "${file}" "${BACKUP_ROOT}/${TODAY}/${db}.dump"
    log "  OK: ${db} (${bytes} bytes)"
  fi
done < <(printf '%s\n' "${ROWS}" | tail -n +2 | sed -e 's/^"//' -e 's/"$//')

if [ "${COUNT}" -eq 0 ]; then
  log "ERROR: backup.all() returned no databases. Output was: ${ROWS}"
  exit 1
fi
log "Processed ${COUNT} databases."

# --- Phase 3: Apply retention ---
"${RETENTION_SCRIPT:-${LIB_DIR}/retention.sh}"

log "=== Backup complete (failures: ${DUMP_FAILED}) ==="
exit ${DUMP_FAILED}
