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
  "s3 cp") echo "$@" >> "${CP_LOG}"; cat > "$(obj "$4")"; [ "${AWS_CP_FAIL:-0}" = 1 ] && exit 1; exit 0 ;;
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
  unset FAIL_DB AWS_CP_FAIL S3_SIZE_OVERRIDE TIMEOUT_EXPIRES BACKUP_DB_TIMEOUT
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
