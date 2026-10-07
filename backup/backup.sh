#!/bin/bash
set -euo pipefail

# Nightly backup through the hot backup plugin: Neo4j keeps running.
# For each database, backup.databaseTo(name, fileName) writes the dump to
# /var/lib/neo4j/backups/<fileName> inside the Neo4j container, which is the same host
# folder mounted here as /backups.
#   S3 mode:    <fileName> is a FIFO; `aws s3 cp -` reads it and streams to S3. Zero local disk.
#   Local mode: <fileName> is a partial file, moved to /backups/<date>/<db>.dump when complete.
# Retention runs only when every database succeeded.

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
NEO4J_CONTAINER=$(resolve_neo4j_container)
BACKUP_ROOT="${BACKUP_ROOT:-/backups}"
HOST_BACKUP_DIR="${HOST_BACKUP_DIR:-}"
S3_BUCKET="${S3_BUCKET:-}"
S3_ENDPOINT="${S3_ENDPOINT:-}"
NEO4J_AUTH="${NEO4J_AUTH:-}"
DATA_DIR="${DATA_DIR:-/data}"
# Upper bound in seconds for one database's backup.databaseTo call (default 6 h, enough for ~100 GB).
BACKUP_DB_TIMEOUT="${BACKUP_DB_TIMEOUT:-21600}"
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

log "=== Starting hot backup (Neo4j stays online) ==="
if s3_configured; then
  log "S3 configured: dumps go to s3://${S3_BUCKET}/${TODAY}/"
  # The settings this run's uploads use (none of them is a secret).
  log "AWS CLI: AWS_REQUEST_CHECKSUM_CALCULATION=${AWS_REQUEST_CHECKSUM_CALCULATION:-<unset>} AWS_RESPONSE_CHECKSUM_VALIDATION=${AWS_RESPONSE_CHECKSUM_VALIDATION:-<unset>} AWS_RETRY_MODE=${AWS_RETRY_MODE:-<unset>} AWS_MAX_ATTEMPTS=${AWS_MAX_ATTEMPTS:-<unset>}"
else
  log "Local mode: dumps go to ${BACKUP_ROOT}/${TODAY}/"
fi

# Never leave a FIFO or a background upload behind, whatever happens.
STREAM_PIDS=""
cleanup_streams() {
  local pid
  for pid in ${STREAM_PIDS}; do kill "${pid}" 2>/dev/null || true; done
  rm -f "${BACKUP_ROOT}"/.stream-*.fifo 2>/dev/null || true
}
trap cleanup_streams EXIT
trap 'exit 130' INT TERM

# --- Phase 1: List databases ---
if ! load_database_list; then
  log "ERROR: could not list databases in ${NEO4J_CONTAINER}: ${DB_LIST_ERROR}"
  exit 1
fi
DATABASES=""
ONLINE=""
while IFS='|' read -r db status; do
  [ -n "${db}" ] || continue
  DATABASES="${DATABASES}${DATABASES:+ }${db}"
  if [ "${status}" = "online" ]; then
    ONLINE="${ONLINE}${ONLINE:+ }${db}"
  else
    log "  FAILED: ${db} (not online: ${status})"
    DUMP_FAILED=1
  fi
done <<< "${DB_ROWS}"
log "Databases: ${DATABASES}"

# run_database_to <db> <fileName>: call the plugin, killed after BACKUP_DB_TIMEOUT seconds.
# On success sets DUMP_BYTES; on failure sets FAIL_REASON. rc 0/1.
run_database_to() {
  local db="$1" file="$2" out row status
  DUMP_BYTES=""; FAIL_REASON=""
  if ! out=$(CYPHER_TIMEOUT="${BACKUP_DB_TIMEOUT}" cypher_rows "${NEO4J_CONTAINER}" neo4j \
      "CALL backup.databaseTo('${db}', '${file}') YIELD database, path, bytes, millis, status RETURN status + '|' + toString(bytes) AS row" 2>&1); then
    FAIL_REASON="backup.databaseTo failed: $(printf '%s' "${out}" | tr '\n' ' ')"
    return 1
  fi
  row=$(printf '%s\n' "${out}" | tail -1)
  status="${row%%|*}"; DUMP_BYTES="${row#*|}"
  if [ "${status}" != "ok" ]; then FAIL_REASON="status: ${status}"; return 1; fi
  case "${DUMP_BYTES}" in ''|*[!0-9]*) FAIL_REASON="unexpected procedure output: ${out}"; return 1 ;; esac
  return 0
}

# start_upload_debug_log <db>: with BACKUP_AWS_DEBUG on, create an empty 0600 debug log for
# <db>'s upload and echo its path. Echoes nothing when off or when the file cannot be created
# (the upload then runs as usual: logging never decides success or failure).
start_upload_debug_log() {
  local db="$1" file
  aws_debug_enabled || return 0
  file="${BACKUP_ROOT}/logs/${TODAY}/${db}-upload.log"
  if mkdir -p "${file%/*}" 2>/dev/null && (umask 077; : > "${file}") 2>/dev/null && chmod 600 "${file}" 2>/dev/null; then
    echo "${file}"
  else
    log "  WARNING: cannot create upload debug log ${file}, uploading without it" >&2
  fi
}

# report_upload_debug_log <file>: after a failed upload, copy the lines of the debug log that
# explain it into the main log, and say where the full log is. The file is kept.
report_upload_debug_log() {
  local file="$1" lines
  lines=$(grep -iE 'traceback|exception|error|retry|retries|closed|timeout|timed out|status code[^0-9]*[45][0-9]{2}|HTTP/1\.[01]" [45][0-9]{2}' "${file}" 2>/dev/null | tail -40) || true
  log "  --- aws upload debug excerpt (last 40 matching lines) ---"
  if [ -n "${lines}" ]; then
    printf '%s\n' "${lines}" | sed 's/^/    | /' || true
  else
    echo "    | (no matching lines)"
  fi
  log "  --- full aws debug log: ${file} ---"
}

# stream_to_s3 <db>: dump <db> through a FIFO straight into S3 as <today>/<db>.dump.
# Nothing touches the local disk. On any failure the S3 object and any open multipart
# upload are removed. Sets DUMP_BYTES / FAIL_REASON. rc 0/1.
# With BACKUP_AWS_DEBUG on, aws runs with --debug and its stderr goes to
# logs/<today>/<db>-upload.log, kept (and excerpted into the main log) only on failure.
stream_to_s3() {
  local db="$1"
  local name=".stream-${db}.fifo"
  local fifo="${BACKUP_ROOT}/${name}" key="${TODAY}/${db}.dump"
  local est aws_pid aws_rc=0 remote debug_log
  DUMP_BYTES=""; FAIL_REASON=""

  est=$(estimate_dump_size "${db}") || true
  if ! [ "${est}" -gt 0 ] 2>/dev/null; then
    FAIL_REASON="cannot estimate its size: ${DATA_DIR}/databases/${db} is not visible (is the Neo4j data dir mounted at ${DATA_DIR}?)"
    return 1
  fi

  rm -f "${fifo}"
  if ! mkfifo "${fifo}" || ! chmod 666 "${fifo}"; then
    FAIL_REASON="cannot create ${fifo}"
    rm -f "${fifo}"
    return 1
  fi

  debug_log=$(start_upload_debug_log "${db}") || debug_log=""
  if [ -n "${debug_log}" ]; then
    aws s3 cp - "s3://${S3_BUCKET}/${key}" --endpoint-url "${S3_ENDPOINT}" --no-progress \
      --expected-size "${est}" --debug < "${fifo}" 2>> "${debug_log}" &
  else
    aws s3 cp - "s3://${S3_BUCKET}/${key}" --endpoint-url "${S3_ENDPOINT}" --no-progress \
      --expected-size "${est}" < "${fifo}" &
  fi
  aws_pid=$!
  STREAM_PIDS="${aws_pid}"

  if run_database_to "${db}" "${name}"; then
    wait "${aws_pid}" || aws_rc=$?
    STREAM_PIDS=""
    rm -f "${fifo}"
    if [ "${aws_rc}" -ne 0 ]; then
      FAIL_REASON="upload failed (aws exit ${aws_rc})"
    else
      remote=$(s3_object_size "${key}")
      if [ "${remote}" != "${DUMP_BYTES}" ]; then
        FAIL_REASON="size mismatch: dump ${DUMP_BYTES} bytes, S3 object ${remote:-missing}"
      fi
    fi
  else
    # aws is either still blocked opening the FIFO (the plugin never opened it) or reading
    # a stream that is no longer wanted (the call failed or timed out while the server may
    # still be writing). Waiting could hang in both cases, so stop it; the object and any
    # multipart upload are discarded below.
    kill "${aws_pid}" 2>/dev/null || true
    wait "${aws_pid}" 2>/dev/null || true
    STREAM_PIDS=""
    rm -f "${fifo}"
  fi

  if [ -n "${FAIL_REASON}" ]; then
    discard_s3_object "${key}"
    [ -z "${debug_log}" ] || report_upload_debug_log "${debug_log}"
    return 1
  fi
  if [ -n "${debug_log}" ]; then
    rm -f "${debug_log}" 2>/dev/null || true
    rmdir "${debug_log%/*}" 2>/dev/null || true
  fi
  return 0
}

# save_locally <db>: dump <db> to a partial file, then move it to <today>/<db>.dump.
save_locally() {
  local db="$1"
  local name=".partial-${db}.dump"
  local partial="${BACKUP_ROOT}/${name}"
  rm -f "${partial}"
  if ! run_database_to "${db}" "${name}"; then
    rm -f "${partial}"
    return 1
  fi
  if [ ! -f "${partial}" ]; then
    FAIL_REASON="plugin wrote ${name} but it is not visible at ${partial}. Is ./data-backup mounted at /var/lib/neo4j/backups on the neo4j service?"
    return 1
  fi
  mkdir -p "${BACKUP_ROOT}/${TODAY}"
  mv -f "${partial}" "${BACKUP_ROOT}/${TODAY}/${db}.dump"
}

# --- Phase 2: Back up each online database ---
for db in ${ONLINE}; do
  log "Backing up ${db}..."
  if s3_configured; then
    if stream_to_s3 "${db}"; then
      log "  OK: ${db} (${DUMP_BYTES} bytes, streamed to s3://${S3_BUCKET}/${TODAY}/${db}.dump)"
    else
      log "  FAILED: ${db} (${FAIL_REASON})"
      DUMP_FAILED=1
    fi
  else
    if save_locally "${db}"; then
      log "  OK: ${db} (${DUMP_BYTES} bytes)"
    else
      log "  FAILED: ${db} (${FAIL_REASON})"
      DUMP_FAILED=1
    fi
  fi
done

# Upload debug logs are kept for 14 days. Never affects the outcome of the run.
prune_upload_debug_logs "${BACKUP_ROOT}/logs" "${TODAY}" 14 | while IFS= read -r d; do log "Removed old upload debug logs: logs/${d}"; done || true

# --- Phase 3: Apply retention, only after a fully successful backup ---
if [ "${DUMP_FAILED}" -ne 0 ]; then
  log "Retention skipped: backup failed, nothing deleted"
  log "=== Backup finished with failures ==="
  exit 1
fi

export BACKUP_DATABASES="${DATABASES}"
if ! "${RETENTION_SCRIPT:-${LIB_DIR}/retention.sh}"; then
  log "ERROR: retention failed (see above)"
  exit 1
fi

log "=== Backup complete ==="
exit 0
