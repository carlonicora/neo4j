#!/bin/bash
# Tests for backup.sh (hot backup plugin flow, backup.databaseTo per database). Bash 3.2 compatible.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/helpers.sh"

echo "syntax: backup.sh"
bash -n "${HERE}/../backup.sh"; assert_success $? "backup.sh parses"

TODAY=$(date +%Y-%m-%d)

# docker stub:
#   exec ... SHOW DATABASES        -> prints the rows in $DBS_FILE ("name|status" per line)
#   exec ... backup.databaseTo(db, f) -> writes DUMPDATA (8 bytes) to $BACKUP_ROOT/f, which
#      blocks on a FIFO until the reader opens it, exactly like the plugin. If db = $FAIL_DB
#      it fails instead without opening the file. Each call is logged in $PROC_LOG, with
#      "fifo" when the target was a FIFO.
#   stop/start/update -> logged in $CTL_LOG: the hot flow must never make one.
# aws stub: `s3 cp -` stores stdin in $S3_DIR (fails after reading when $AWS_CP_FAIL=1),
# `s3 ls` reports the stored size (or $S3_SIZE_OVERRIDE), `s3 rm` and multipart aborts are logged.
setup_backup_stubs() {
  make_stub docker '
case "$1" in
  exec)
    for a in "$@"; do q="$a"; done
    case "$q" in
      *"SHOW DATABASES"*) echo row; sed "s/.*/\"&\"/" "${DBS_FILE}"; exit 0 ;;
      *backup.databaseTo*)
        db=$(printf "%s" "$q" | sed "s/.*databaseTo(.\([^,]*\)., .\([^)]*\).).*/\1/")
        f=$(printf "%s" "$q" | sed "s/.*databaseTo(.\([^,]*\)., .\([^)]*\).).*/\2/")
        kind=file; [ -p "${BACKUP_ROOT}/${f}" ] && kind=fifo
        echo "${db} ${f} ${kind}" >> "${PROC_LOG}"
        if [ "${db}" = "${FAIL_DB:-}" ]; then echo "Failed to invoke procedure backup.databaseTo: boom" >&2; exit 1; fi
        printf DUMPDATA > "${BACKUP_ROOT}/${f}" || exit 1
        echo row; echo "\"ok|8\""; exit 0 ;;
    esac ;;
  stop|start|update) echo "$1" >> "${CTL_LOG}"; exit 0 ;;
  ps) echo "neo4j-neo4j-1" ;;
esac'
  make_stub aws '
obj() { printf "%s" "${S3_DIR}/$(printf "%s" "${1#s3://b/}" | tr / _)"; }
case "$1 $2" in
  "s3 cp") echo "$@" >> "${CP_LOG}"; cat > "$(obj "$4")"
           case " $* " in *" --debug "*)
             echo "2026-10-07 02:00:01,000 - MainThread - botocore.endpoint - DEBUG - Making request for OperationModel(name=UploadPart)" >&2
             echo "2026-10-07 02:00:02,000 - MainThread - urllib3.connectionpool - DEBUG - \"PUT /b/key?partNumber=59 HTTP/1.1\" 503 0" >&2
             [ "${AWS_CP_FAIL:-0}" = 1 ] && echo "botocore.exceptions.ConnectionClosedError: Connection was closed before we received a valid response" >&2 ;;
           esac
           [ "${AWS_CP_FAIL:-0}" = 1 ] && exit 1; exit 0 ;;
  "s3 ls") f=$(obj "$3"); [ -f "$f" ] || exit 1
           echo "2026-10-07 02:00:01 ${S3_SIZE_OVERRIDE:-$(wc -c < "$f" | tr -d " ")} $(basename "$3")"; exit 0 ;;
  "s3 rm") echo "$3" >> "${RM_LOG}"; rm -f "$(obj "$3")"; exit 0 ;;
  "s3api list-multipart-uploads") echo "UP1"; exit 0 ;;
  "s3api abort-multipart-upload") echo "$@" >> "${ABORT_LOG}"; exit 0 ;;
esac'
  # timeout stub: logs the limit, then runs the command (or "times out" with rc 124 when
  # $TIMEOUT_EXPIRES=1, without running it).
  make_stub timeout 'echo "$1" >> "${TIMEOUT_LOG}"; shift; [ "${TIMEOUT_EXPIRES:-0}" = 1 ] && exit 124; exec "$@"'
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/bk.XXXXXX")"
  mkdir -p "${WORK}/backups" "${WORK}/s3" "${WORK}/data/databases" "${WORK}/data/transactions"
  export BACKUP_ROOT="${WORK}/backups" DATA_DIR="${WORK}/data" S3_DIR="${WORK}/s3"
  export DBS_FILE="${WORK}/dbs" PROC_LOG="${WORK}/proc.log" CTL_LOG="${WORK}/ctl.log" CP_LOG="${WORK}/cp.log"
  export RM_LOG="${WORK}/rm.log" ABORT_LOG="${WORK}/abort.log" RET_LOG="${WORK}/ret.log" TIMEOUT_LOG="${WORK}/timeout.log"
  : > "${TIMEOUT_LOG}"; : > "${PROC_LOG}"; : > "${CTL_LOG}"; : > "${CP_LOG}"; : > "${RM_LOG}"; : > "${ABORT_LOG}"
  RETENTION_SCRIPT="${WORK}/retention-stub.sh"
  printf '#!/bin/bash\necho "ran with: ${BACKUP_DATABASES}" >> "${RET_LOG}"\nexit 0\n' > "${RETENTION_SCRIPT}"; chmod +x "${RETENTION_SCRIPT}"
  export RETENTION_SCRIPT
  unset FAIL_DB AWS_CP_FAIL S3_SIZE_OVERRIDE TIMEOUT_EXPIRES BACKUP_DB_TIMEOUT BACKUP_AWS_DEBUG
  unset AWS_REQUEST_CHECKSUM_CALCULATION AWS_RESPONSE_CHECKSUM_VALIDATION AWS_RETRY_MODE AWS_MAX_ATTEMPTS
}
teardown_backup_stubs() { rm -rf "${WORK}"; }

# with_dbs "neo4j|online" "system|online" ...: the database list, each with a store on /data
with_dbs() {
  local row
  : > "${DBS_FILE}"
  for row in "$@"; do
    echo "${row}" >> "${DBS_FILE}"
    mkdir -p "${DATA_DIR}/databases/${row%%|*}"; printf store > "${DATA_DIR}/databases/${row%%|*}/neostore"
  done
}
run_local() { HOST_BACKUP_DIR="${BACKUP_ROOT}" S3_BUCKET="" S3_ENDPOINT="" NEO4J_AUTH="neo4j/secret" bash "${HERE}/../backup.sh" > "${WORK}/out.log" 2>&1; }
run_s3() { HOST_BACKUP_DIR="" S3_BUCKET="b" S3_ENDPOINT="https://e" NEO4J_AUTH="neo4j/secret" bash "${HERE}/../backup.sh" > "${WORK}/out.log" 2>&1; }
logged() { if grep -q -- "$1" "${WORK}/out.log"; then assert_success 0 "$2"; else assert_failure 0 "$2"; echo "    --- out.log:"; sed 's/^/    /' "${WORK}/out.log"; fi; }
local_leftovers() { find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 \( -name '.stream-*' -o -name '.partial-*' -o -name '*.dump' \) | wc -l | tr -d ' '; }

echo "test: S3 mode streams every database through a FIFO, nothing on local disk"
setup_stub_path; setup_backup_stubs
with_dbs "neo4j|online" "system|online"
run_s3; RC=$?
assert_success ${RC} "S3-mode run succeeds"
assert_eq "DUMPDATA" "$(cat "${S3_DIR}/${TODAY}_neo4j.dump" 2>/dev/null)" "neo4j streamed to <date>/neo4j.dump"
assert_eq "DUMPDATA" "$(cat "${S3_DIR}/${TODAY}_system.dump" 2>/dev/null)" "system streamed to <date>/system.dump"
assert_eq "2" "$(grep -c ' fifo$' "${PROC_LOG}")" "the plugin wrote into a FIFO each time"
if grep -q -- "--expected-size" "${CP_LOG}"; then assert_success 0 "aws s3 cp gets --expected-size"; else assert_failure 0 "aws s3 cp gets --expected-size"; fi
assert_eq "0" "$(local_leftovers)" "no FIFO, partial or dump left locally"
assert_eq "0" "$(find "${BACKUP_ROOT}" -mindepth 1 | wc -l | tr -d ' ')" "local backup dir untouched"
assert_eq "" "$(cat "${RM_LOG}")" "nothing deleted from S3"
assert_eq "ran with: neo4j system" "$(cat "${RET_LOG}" 2>/dev/null)" "retention ran with the database list"
logged "OK: neo4j (8 bytes" "one OK line per database with bytes"
assert_eq "21600 21600" "$(tr '\n' ' ' < "${TIMEOUT_LOG}" | sed 's/ $//')" "each procedure call is bounded by the 6 h default timeout"
assert_eq "" "$(cat "${CTL_LOG}")" "no docker stop/start/update"
teardown_backup_stubs; teardown_stub_path

echo "test: S3 mode procedure failure removes FIFO, object and multipart upload, skips retention"
setup_stub_path; setup_backup_stubs
with_dbs "neo4j|online" "avvocato360|online"
export FAIL_DB=avvocato360
run_s3; RC=$?
assert_failure ${RC} "procedure failure => non-zero exit"
assert_eq "0" "$(local_leftovers)" "FIFO removed"
if grep -q "s3://b/${TODAY}/avvocato360.dump" "${RM_LOG}"; then assert_success 0 "S3 object deleted"; else assert_failure 0 "S3 object deleted"; fi
if grep -q -- "--key ${TODAY}/avvocato360.dump --upload-id UP1" "${ABORT_LOG}"; then assert_success 0 "multipart upload aborted"; else assert_failure 0 "multipart upload aborted"; fi
assert_eq "DUMPDATA" "$(cat "${S3_DIR}/${TODAY}_neo4j.dump" 2>/dev/null)" "the other database is still backed up"
logged "FAILED: avvocato360 (backup.databaseTo failed: .*boom" "failure logged with the reason"
logged "Retention skipped: backup failed, nothing deleted" "retention skip logged"
if [ -f "${RET_LOG}" ]; then assert_failure 0 "retention not run"; else assert_success 0 "retention not run"; fi
teardown_backup_stubs; teardown_stub_path

echo "test: S3 mode procedure timeout stops the reader, discards the object, skips retention"
setup_stub_path; setup_backup_stubs
with_dbs "neo4j|online"
export TIMEOUT_EXPIRES=1 BACKUP_DB_TIMEOUT=5
run_s3; RC=$?
assert_failure ${RC} "timeout => non-zero exit"
assert_eq "5" "$(cat "${TIMEOUT_LOG}")" "BACKUP_DB_TIMEOUT is honoured"
logged "FAILED: neo4j (backup.databaseTo failed: timed out after 5s" "timeout logged"
if grep -q "s3://b/${TODAY}/neo4j.dump" "${RM_LOG}"; then assert_success 0 "object deleted"; else assert_failure 0 "object deleted"; fi
if [ -s "${ABORT_LOG}" ]; then assert_success 0 "multipart uploads aborted"; else assert_failure 0 "multipart uploads aborted"; fi
assert_eq "0" "$(local_leftovers)" "FIFO removed"
logged "Retention skipped" "retention skipped"
teardown_backup_stubs; teardown_stub_path

echo "test: S3 mode size mismatch deletes the object and fails"
setup_stub_path; setup_backup_stubs
with_dbs "neo4j|online"
export S3_SIZE_OVERRIDE=5
run_s3; RC=$?
assert_failure ${RC} "size mismatch => non-zero exit"
if grep -q "s3://b/${TODAY}/neo4j.dump" "${RM_LOG}"; then assert_success 0 "object deleted"; else assert_failure 0 "object deleted"; fi
if [ -s "${ABORT_LOG}" ]; then assert_success 0 "multipart uploads aborted"; else assert_failure 0 "multipart uploads aborted"; fi
logged "size mismatch: dump 8 bytes, S3 object 5" "mismatch logged"
logged "Retention skipped" "retention skipped"
assert_eq "0" "$(local_leftovers)" "FIFO removed"
teardown_backup_stubs; teardown_stub_path

echo "test: S3 mode aws failure deletes the object and fails, nothing kept for retry"
setup_stub_path; setup_backup_stubs
with_dbs "neo4j|online"
export AWS_CP_FAIL=1
run_s3; RC=$?
assert_failure ${RC} "aws failure => non-zero exit"
if grep -q "s3://b/${TODAY}/neo4j.dump" "${RM_LOG}"; then assert_success 0 "object deleted"; else assert_failure 0 "object deleted"; fi
logged "upload failed (aws exit 1)" "aws failure logged"
assert_eq "0" "$(find "${BACKUP_ROOT}" -mindepth 1 | wc -l | tr -d ' ')" "nothing kept locally"
if [ -f "${RET_LOG}" ]; then assert_failure 0 "retention not run"; else assert_success 0 "retention not run"; fi
teardown_backup_stubs; teardown_stub_path

echo "test: S3 mode logs the effective aws-cli checksum and retry settings"
setup_stub_path; setup_backup_stubs
with_dbs "neo4j|online"
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required AWS_RETRY_MODE=standard AWS_MAX_ATTEMPTS=10
run_s3; RC=$?
assert_success ${RC} "run succeeds"
logged "AWS CLI: AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required AWS_RETRY_MODE=standard AWS_MAX_ATTEMPTS=10" "the four settings logged"
assert_eq "1" "$(grep -c "AWS CLI:" "${WORK}/out.log")" "logged once per run"
teardown_backup_stubs; teardown_stub_path

echo "test: BACKUP_AWS_DEBUG off: no --debug, no logs folder"
setup_stub_path; setup_backup_stubs
with_dbs "neo4j|online"
run_s3; RC=$?
assert_success ${RC} "run succeeds"
if grep -q -- "--debug" "${CP_LOG}"; then assert_failure 0 "no --debug passed"; else assert_success 0 "no --debug passed"; fi
if [ -e "${BACKUP_ROOT}/logs" ]; then assert_failure 0 "no logs folder created"; else assert_success 0 "no logs folder created"; fi
teardown_backup_stubs; teardown_stub_path

echo "test: BACKUP_AWS_DEBUG on, upload succeeds: --debug passed, no log left"
setup_stub_path; setup_backup_stubs
with_dbs "neo4j|online"
export BACKUP_AWS_DEBUG=1
run_s3; RC=$?
assert_success ${RC} "run succeeds"
if grep -q -- "--debug" "${CP_LOG}"; then assert_success 0 "--debug passed"; else assert_failure 0 "--debug passed"; fi
assert_eq "0" "$(find "${BACKUP_ROOT}/logs" -type f 2>/dev/null | wc -l | tr -d ' ')" "debug log deleted"
if [ -e "${BACKUP_ROOT}/logs/${TODAY}" ]; then assert_failure 0 "empty date folder removed"; else assert_success 0 "empty date folder removed"; fi
if grep -q "partNumber" "${WORK}/out.log"; then assert_failure 0 "debug output kept out of the main log"; else assert_success 0 "debug output kept out of the main log"; fi
teardown_backup_stubs; teardown_stub_path

echo "test: BACKUP_AWS_DEBUG on, upload fails: log kept, excerpt in the main log, outcome unchanged"
setup_stub_path; setup_backup_stubs
with_dbs "neo4j|online"
export BACKUP_AWS_DEBUG=true AWS_CP_FAIL=1
run_s3; RC=$?
assert_failure ${RC} "aws failure => non-zero exit"
DBG="${BACKUP_ROOT}/logs/${TODAY}/neo4j-upload.log"
if grep -q "ConnectionClosedError" "${DBG}" 2>/dev/null; then assert_success 0 "debug log kept with aws stderr"; else assert_failure 0 "debug log kept with aws stderr"; fi
assert_eq "600" "$(stat -f %Lp "${DBG}" 2>/dev/null || stat -c %a "${DBG}")" "debug log is 0600"
logged "upload failed (aws exit 1)" "failure reason unchanged"
logged "aws upload debug excerpt" "excerpt header in the main log"
logged "| botocore.exceptions.ConnectionClosedError: Connection was closed" "exception line excerpted"
logged "partNumber=59 HTTP/1.1\" 503" "5xx status line excerpted"
if grep -q "Making request for OperationModel" "${WORK}/out.log"; then assert_failure 0 "unrelated debug lines left out"; else assert_success 0 "unrelated debug lines left out"; fi
logged "full aws debug log: ${DBG}" "log path given"
if grep -q "s3://b/${TODAY}/neo4j.dump" "${RM_LOG}"; then assert_success 0 "object still discarded"; else assert_failure 0 "object still discarded"; fi
teardown_backup_stubs; teardown_stub_path

echo "test: upload debug log folders older than 14 days are pruned, other entries kept"
setup_stub_path; setup_backup_stubs
with_dbs "neo4j|online"
OLD=$(date -d "-15 days" +%Y-%m-%d 2>/dev/null || date -v-15d +%Y-%m-%d)
EDGE=$(date -d "-14 days" +%Y-%m-%d 2>/dev/null || date -v-14d +%Y-%m-%d)
mkdir -p "${BACKUP_ROOT}/logs/${OLD}" "${BACKUP_ROOT}/logs/${EDGE}" "${BACKUP_ROOT}/logs/notes"
printf x > "${BACKUP_ROOT}/logs/${OLD}/neo4j-upload.log"; printf x > "${BACKUP_ROOT}/logs/${EDGE}/neo4j-upload.log"
printf x > "${BACKUP_ROOT}/logs/README"
run_s3; RC=$?
assert_success ${RC} "run succeeds"
if [ -d "${BACKUP_ROOT}/logs/${OLD}" ]; then assert_failure 0 "15-day-old folder removed"; else assert_success 0 "15-day-old folder removed"; fi
if [ -d "${BACKUP_ROOT}/logs/${EDGE}" ]; then assert_success 0 "14-day-old folder kept"; else assert_failure 0 "14-day-old folder kept"; fi
if [ -d "${BACKUP_ROOT}/logs/notes" ] && [ -f "${BACKUP_ROOT}/logs/README" ]; then assert_success 0 "non-date entries kept"; else assert_failure 0 "non-date entries kept"; fi
logged "Removed old upload debug logs: logs/${OLD}" "pruning logged"
teardown_backup_stubs; teardown_stub_path

echo "test: pruning also runs on a failed night"
setup_stub_path; setup_backup_stubs
with_dbs "neo4j|online"
export AWS_CP_FAIL=1
mkdir -p "${BACKUP_ROOT}/logs/2020-01-01"
run_s3; RC=$?
assert_failure ${RC} "failure => non-zero exit"
if [ -d "${BACKUP_ROOT}/logs/2020-01-01" ]; then assert_failure 0 "old folder removed"; else assert_success 0 "old folder removed"; fi
teardown_backup_stubs; teardown_stub_path

echo "test: S3 mode without a visible store fails that database (no --expected-size, no upload)"
setup_stub_path; setup_backup_stubs
with_dbs "neo4j|online"
rm -rf "${DATA_DIR}/databases/neo4j"
run_s3; RC=$?
assert_failure ${RC} "no estimate => non-zero exit"
assert_eq "" "$(cat "${CP_LOG}")" "no upload started"
logged "cannot estimate its size" "reason logged"
teardown_backup_stubs; teardown_stub_path

echo "test: local mode files each dump as <date>/<db>.dump via a partial file"
setup_stub_path; setup_backup_stubs
with_dbs "neo4j|online" "system|online"
run_local; RC=$?
assert_success ${RC} "local-mode run succeeds"
assert_eq "DUMPDATA" "$(cat "${BACKUP_ROOT}/${TODAY}/neo4j.dump" 2>/dev/null)" "neo4j filed under today's date"
assert_eq "DUMPDATA" "$(cat "${BACKUP_ROOT}/${TODAY}/system.dump" 2>/dev/null)" "system filed under today's date"
if grep -q "neo4j .partial-neo4j.dump file" "${PROC_LOG}"; then assert_success 0 "plugin wrote a partial regular file"; else assert_failure 0 "plugin wrote a partial regular file"; fi
assert_eq "0" "$(local_leftovers)" "no partial left in the root"
assert_eq "" "$(cat "${CP_LOG}")" "no S3 call"
assert_eq "" "$(cat "${CTL_LOG}")" "no docker stop/start/update"
teardown_backup_stubs; teardown_stub_path

echo "test: local mode procedure failure removes the partial file and skips retention"
setup_stub_path; setup_backup_stubs
with_dbs "neo4j|online" "phlow|online"
export FAIL_DB=phlow
printf stale > "${BACKUP_ROOT}/.partial-phlow.dump"
run_local; RC=$?
assert_failure ${RC} "failure => non-zero exit"
assert_eq "0" "$(local_leftovers)" "partial removed"
if [ -f "${BACKUP_ROOT}/${TODAY}/neo4j.dump" ]; then assert_success 0 "ok database still filed"; else assert_failure 0 "ok database still filed"; fi
if [ -f "${BACKUP_ROOT}/${TODAY}/phlow.dump" ]; then assert_failure 0 "failed database not filed"; else assert_success 0 "failed database not filed"; fi
logged "Retention skipped: backup failed, nothing deleted" "retention skip logged"
teardown_backup_stubs; teardown_stub_path

echo "test: a database that is not online is a failure, the others are still backed up"
setup_stub_path; setup_backup_stubs
with_dbs "neo4j|online" "uso|offline"
run_local; RC=$?
assert_failure ${RC} "offline database => non-zero exit"
logged "FAILED: uso (not online: offline)" "offline database logged as FAILED"
if [ -f "${BACKUP_ROOT}/${TODAY}/neo4j.dump" ]; then assert_success 0 "online database still filed"; else assert_failure 0 "online database still filed"; fi
if grep -q "^uso " "${PROC_LOG}"; then assert_failure 0 "offline database not attempted"; else assert_success 0 "offline database not attempted"; fi
if [ -f "${RET_LOG}" ]; then assert_failure 0 "retention not run"; else assert_success 0 "retention not run"; fi
teardown_backup_stubs; teardown_stub_path

echo "test: database list failure aborts with its output"
setup_stub_path; setup_backup_stubs
make_stub docker 'case "$1" in exec) echo "Connection refused" >&2; exit 1 ;; ps) echo "neo4j-neo4j-1" ;; esac'
run_local; RC=$?
assert_failure ${RC} "list failure => non-zero exit"
logged "could not list databases.*Connection refused" "error surfaced in the log"
teardown_backup_stubs; teardown_stub_path

echo "test: missing NEO4J_AUTH aborts"
setup_stub_path; setup_backup_stubs
HOST_BACKUP_DIR="${BACKUP_ROOT}" S3_BUCKET="" S3_ENDPOINT="" NEO4J_AUTH="" \
  bash "${HERE}/../backup.sh" > "${WORK}/out.log" 2>&1
assert_failure $? "no credentials => non-zero exit"
teardown_backup_stubs; teardown_stub_path

echo "test: not configured (no HOST_BACKUP_DIR, no S3) skips quietly"
setup_stub_path; setup_backup_stubs
HOST_BACKUP_DIR="" S3_BUCKET="" S3_ENDPOINT="" NEO4J_AUTH="neo4j/secret" bash "${HERE}/../backup.sh" >/dev/null 2>&1
assert_success $? "skip => exit 0"
teardown_backup_stubs; teardown_stub_path

finish
