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

log() { echo "${LOG_PREFIX} $(date +%H:%M:%S) $*"; }

# --- Policy ---
# An invalid policy must never delete anything: fail loudly instead.
if ! REASON=$(retention_validate "${RETENTION}" 2>&1); then
  log "ERROR: BACKUP_RETENTION='${RETENTION}' is invalid: ${REASON}. Nothing deleted."
  exit 1
fi
log "Policy: ${RETENTION}"

# Echo the rule that keeps <date>, or nothing if <date> is to be deleted. <keep> is the
# output of retention_keep_dates.
kept_by() {
  local date="$1" keep="$2"
  printf '%s\n' "${keep}" | awk -v d="${date}" '$1 == d { print $2; exit }'
}

# --- Local retention ---
if s3_configured; then
  # S3 mode: dumps are uploaded by backup.sh. Drain any local backlog (failed uploads)
  # to S3 (verified) and delete it. Keeps unverified dirs for retry.
  log "S3 mode: draining local backlog (if any)..."
  drain_local_backlog
else
  LOCAL_DATES=()
  for dir in "${BACKUP_ROOT}"/????-??-??; do
    [ -d "$dir" ] || continue
    LOCAL_DATES+=("$(basename "$dir")")
  done
  if [ ${#LOCAL_DATES[@]} -gt 0 ]; then
    KEEP=$(retention_keep_dates "${RETENTION}" "${LOCAL_DATES[@]}")
    for dir_date in "${LOCAL_DATES[@]}"; do
      rule=$(kept_by "${dir_date}" "${KEEP}")
      if [ -n "${rule}" ]; then
        log "Keeping local: ${dir_date} (${rule})"
      else
        log "Removing local: ${dir_date}"
        rm -rf "${BACKUP_ROOT:?}/${dir_date}"
      fi
    done
  fi
fi

# --- S3 retention ---
if s3_configured; then
  log "Applying S3 retention..."
  S3_DATES=()
  while read -r s3_date; do
    [ -n "${s3_date}" ] && S3_DATES+=("${s3_date}")
  done < <(aws s3 ls "s3://${S3_BUCKET}/" --endpoint-url "${S3_ENDPOINT}" 2>/dev/null \
            | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | sort -u)
  if [ ${#S3_DATES[@]} -gt 0 ]; then
    KEEP=$(retention_keep_dates "${RETENTION}" "${S3_DATES[@]}")
    for s3_date in "${S3_DATES[@]}"; do
      rule=$(kept_by "${s3_date}" "${KEEP}")
      if [ -n "${rule}" ]; then
        log "Keeping S3: ${s3_date} (${rule})"
      else
        log "Removing S3: ${s3_date}/"
        aws s3 rm "s3://${S3_BUCKET}/${s3_date}/" \
          --recursive \
          --endpoint-url "${S3_ENDPOINT}" \
          --quiet 2>&1 || log "WARNING: Failed to remove S3 prefix ${s3_date}"
      fi
    done
  fi
fi

log "Retention complete."
