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

BACKUP_ROOT="${BACKUP_ROOT:-/backups}"
S3_BUCKET="${S3_BUCKET:-}"
S3_ENDPOINT="${S3_ENDPOINT:-}"
RETENTION="${BACKUP_RETENTION:-${RETENTION_DEFAULT}}"
LOG_PREFIX="[retention]"
TODAY=$(date +%Y-%m-%d)

log() { echo "${LOG_PREFIX} $(date +%H:%M:%S) $*"; }

# --- Policy ---
# An invalid policy must never delete anything: fail loudly instead.
if ! REASON=$(retention_validate "${RETENTION}" 2>&1); then
  log "ERROR: BACKUP_RETENTION='${RETENTION}' is invalid: ${REASON}. Nothing deleted."
  exit 1
fi
log "Policy: ${RETENTION}"

# --- Current database list: a date is complete only with a dump of every one ---
if [ -n "${BACKUP_DATABASES+set}" ]; then
  DATABASES="${BACKUP_DATABASES}"
else
  if [ -z "${NEO4J_AUTH:-}" ]; then
    log "ERROR: BACKUP_DATABASES not set and NEO4J_AUTH not set, cannot list databases. Nothing deleted."
    exit 1
  fi
  NEO4J_CONTAINER=$(resolve_neo4j_container)
  if ! load_database_list; then
    log "ERROR: could not list databases in ${NEO4J_CONTAINER}: ${DB_LIST_ERROR}. Nothing deleted."
    exit 1
  fi
  DATABASES=$(printf '%s\n' "${DB_ROWS}" | cut -d'|' -f1 | tr '\n' ' ' | sed 's/ *$//')
fi
if [ -z "${DATABASES// /}" ]; then
  log "ERROR: the database list is empty. Nothing deleted."
  exit 1
fi
log "Databases a complete backup must hold: ${DATABASES}"

# --- Inventory: "<date> <file name>" for every dump, local folders or S3 prefixes ---
if s3_configured; then
  WHERE="S3"
  if ! LISTING=$(aws s3 ls "s3://${S3_BUCKET}/" --recursive --endpoint-url "${S3_ENDPOINT}" 2>&1); then
    log "ERROR: cannot list s3://${S3_BUCKET}/: ${LISTING}. Nothing deleted."
    exit 1
  fi
  INVENTORY=$(printf '%s\n' "${LISTING}" | awk '{print $4}' \
    | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}/' | sed 's#/# #' || true)
else
  WHERE="local"
  INVENTORY=""
  for dir in "${BACKUP_ROOT}"/????-??-??; do
    [ -d "${dir}" ] || continue
    d=$(basename "${dir}")
    INVENTORY="${INVENTORY}${d} .
"
    for f in "${dir}"/*; do
      if [ -f "${f}" ]; then INVENTORY="${INVENTORY}${d} $(basename "${f}")
"; fi
    done
  done
fi

ALL_DATES=$(printf '%s\n' "${INVENTORY}" | awk '{print $1}' | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' | sort -u || true)
if [ -z "${ALL_DATES}" ]; then
  log "No ${WHERE} backups found. Nothing to do."
  exit 0
fi

COMPLETE=""
INCOMPLETE_REASONS=""
for d in ${ALL_DATES}; do
  names=$(printf '%s\n' "${INVENTORY}" | awk -v d="${d}" '$1 == d { print $2 }' | tr '\n' ' ')
  missing=$(missing_databases "${names}" "${DATABASES}")
  if [ -z "${missing}" ]; then
    COMPLETE="${COMPLETE} ${d}"
  else
    INCOMPLETE_REASONS="${INCOMPLETE_REASONS}${d} ${missing}
"
  fi
done

if [ -z "${COMPLETE// /}" ]; then
  log "ERROR: no complete ${WHERE} backup (every date misses a database). Refusing to delete anything."
  exit 1
fi

# shellcheck disable=SC2086
KEEP=$(retention_keep_dates "${RETENTION}" "${TODAY}" ${COMPLETE})
if [ -z "${KEEP}" ]; then
  log "ERROR: policy '${RETENTION}' would leave no complete ${WHERE} backup (none falls in its windows as of ${TODAY}). Refusing to delete anything."
  exit 1
fi

remove_date() {
  local d="$1"
  if s3_configured; then
    aws s3 rm "s3://${S3_BUCKET}/${d}/" \
      --recursive \
      --endpoint-url "${S3_ENDPOINT}" \
      --quiet 2>&1 || log "WARNING: Failed to remove S3 prefix ${d}"
  else
    rm -rf "${BACKUP_ROOT:?}/${d}"
  fi
}

for d in ${ALL_DATES}; do
  rule=$(printf '%s\n' "${KEEP}" | awk -v d="${d}" '$1 == d { print $2; exit }')
  missing=$(printf '%s' "${INCOMPLETE_REASONS}" | awk -v d="${d}" '$1 == d { $1 = ""; sub(/^ /, ""); print; exit }')
  if [ -n "${rule}" ]; then
    log "Keeping ${WHERE}: ${d} (${rule})"
  elif [ -n "${missing}" ]; then
    log "Removing ${WHERE}: ${d} (incomplete, missing: ${missing})"
    remove_date "${d}"
  else
    log "Removing ${WHERE}: ${d}"
    remove_date "${d}"
  fi
done

log "Retention complete."
