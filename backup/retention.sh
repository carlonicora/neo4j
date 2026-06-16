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
TODAY_EPOCH=$(date +%s)
S3_BUCKET="${S3_BUCKET:-}"
S3_ENDPOINT="${S3_ENDPOINT:-}"
LOG_PREFIX="[retention]"

log() { echo "${LOG_PREFIX} $(date +%H:%M:%S) $*"; }

# Determine if a date should be kept based on retention policy:
#   - Daily:   keep all backups for 7 days
#   - Weekly:  keep Sunday backups for 28 days
#   - Monthly: keep 1st-of-month backups for 365 days
should_keep() {
  local dir_date="$1" # YYYY-MM-DD format
  local dir_epoch day_of_week day_of_month age_days

  # Parse date (GNU date syntax - works in Alpine/Docker)
  dir_epoch=$(date -d "${dir_date}" +%s 2>/dev/null) || return 1
  day_of_week=$(date -d "${dir_date}" +%u 2>/dev/null) || return 1
  day_of_month=$(date -d "${dir_date}" +%d 2>/dev/null) || return 1

  age_days=$(( (TODAY_EPOCH - dir_epoch) / 86400 ))

  # Daily: keep last 7 days
  if [ "$age_days" -le 7 ]; then
    return 0
  fi

  # Weekly: keep Sundays for 28 days (day_of_week 7 = Sunday in ISO format)
  if [ "$day_of_week" -eq 7 ] && [ "$age_days" -le 28 ]; then
    return 0
  fi

  # Monthly: keep 1st-of-month for 365 days
  if [ "$day_of_month" = "01" ] && [ "$age_days" -le 365 ]; then
    return 0
  fi

  return 1
}

log "Applying retention policy..."

# --- Local retention ---
if s3_configured; then
  # S3 mode: new dumps never land locally. Drain any pre-existing local backlog
  # to S3 (verified) and delete it. Keeps unverified dirs for retry.
  log "S3 mode: draining local backlog (if any)..."
  drain_local_backlog
else
  for dir in "${BACKUP_ROOT}"/????-??-??; do
    [ -d "$dir" ] || continue
    dir_date=$(basename "$dir")

    if should_keep "$dir_date"; then
      log "Keeping local: ${dir_date}"
    else
      log "Removing local: ${dir_date}"
      rm -rf "$dir"
    fi
  done
fi

# --- S3 retention ---
if [ -n "${S3_BUCKET}" ] && [ -n "${S3_ENDPOINT}" ]; then
  log "Applying S3 retention..."

  aws s3 ls "s3://${S3_BUCKET}/" --endpoint-url "${S3_ENDPOINT}" 2>/dev/null | \
    grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | sort -u | while read -r s3_date; do
    if should_keep "$s3_date"; then
      log "Keeping S3: ${s3_date}"
    else
      log "Removing S3: ${s3_date}/"
      aws s3 rm "s3://${S3_BUCKET}/${s3_date}/" \
        --recursive \
        --endpoint-url "${S3_ENDPOINT}" \
        --quiet 2>&1 || log "WARNING: Failed to remove S3 prefix ${s3_date}"
    fi
  done
fi

log "Retention complete."
