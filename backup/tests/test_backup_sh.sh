#!/bin/bash
# Tests for backup.sh (hot backup plugin flow). Bash 3.2 compatible.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/helpers.sh"

echo "syntax: backup.sh"
bash -n "${HERE}/../backup.sh"; assert_success $? "backup.sh parses"

TODAY=$(date +%Y-%m-%d)

# docker stub: `exec ... cypher-shell` writes the dump files the plugin would write into
# $BACKUP_ROOT and prints the rows backup.all() would return (from $ROWS_FILE).
# Any stop/start/update call is recorded in $CTL_LOG: the hot flow must never make one.
setup_backup_stubs() {
  make_stub docker '
case "$1" in
  exec)
    for f in $(grep -o "backups/[^|]*\.dump" "${ROWS_FILE}" | sed "s#backups/##"); do printf DUMPDATA > "${BACKUP_ROOT}/${f}"; done
    echo "row"; cat "${ROWS_FILE}"; exit 0 ;;
  stop|start|update) echo "$1" >> "${CTL_LOG}"; exit 0 ;;
  ps) echo "neo4j-neo4j-1" ;;
esac'
  RETENTION_SCRIPT="$(mktemp "${TMPDIR:-/tmp}/ret.XXXXXX")"; printf '#!/bin/bash\nexit 0\n' > "${RETENTION_SCRIPT}"; chmod +x "${RETENTION_SCRIPT}"
  export RETENTION_SCRIPT
  CTL_LOG="$(mktemp "${TMPDIR:-/tmp}/ctl.XXXXXX")"; export CTL_LOG
  ROWS_FILE="$(mktemp "${TMPDIR:-/tmp}/rows.XXXXXX")"; export ROWS_FILE
}
teardown_backup_stubs() { rm -f "${RETENTION_SCRIPT}" "${CTL_LOG}" "${ROWS_FILE}"; }

echo "test: local mode files each dump as <date>/<db>.dump, Neo4j never stopped"
setup_stub_path; setup_backup_stubs
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bk.XXXXXX")"; mkdir -p "${WORK}/backups"; export BACKUP_ROOT="${WORK}/backups"
printf '"neo4j|/var/lib/neo4j/backups/neo4j-20261006-020000.dump|8|ok"\n"system|/var/lib/neo4j/backups/system-20261006-020001.dump|8|ok"\n' > "${ROWS_FILE}"
HOST_BACKUP_DIR="${WORK}/backups" S3_BUCKET="" S3_ENDPOINT="" NEO4J_AUTH="neo4j/secret" \
  bash "${HERE}/../backup.sh" > "${WORK}/out.log" 2>&1
assert_success $? "local-mode run succeeds"
if [ -f "${WORK}/backups/${TODAY}/neo4j.dump" ] && [ -f "${WORK}/backups/${TODAY}/system.dump" ]; then assert_success 0 "dumps filed under today's date"; else assert_failure 0 "dumps filed under today's date"; fi
assert_eq "DUMPDATA" "$(cat "${WORK}/backups/${TODAY}/neo4j.dump")" "filed dump is the plugin's file"
assert_eq "0" "$(ls "${WORK}/backups"/*.dump 2>/dev/null | wc -l | tr -d ' ')" "no loose dump left in the root"
assert_eq "" "$(cat "${CTL_LOG}")" "no docker stop/start/update"
rm -rf "${WORK}"; teardown_backup_stubs; teardown_stub_path

echo "test: S3 mode uploads as <date>/<db>.dump and removes the local file"
setup_stub_path; setup_backup_stubs
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bk.XXXXXX")"; mkdir -p "${WORK}/backups"; export BACKUP_ROOT="${WORK}/backups"
printf '"neo4j|/var/lib/neo4j/backups/neo4j-20261006-020000.dump|8|ok"\n' > "${ROWS_FILE}"
make_stub aws '
case "$1 $2" in
  "s3 cp") echo "$@" >> "${CP_LOG}"; exit 0 ;;
  "s3 ls") echo "2026-10-06 02:00:01      8 neo4j.dump"; exit 0 ;;
  "s3 rm") exit 0 ;;
esac'
CP_LOG="$(mktemp "${TMPDIR:-/tmp}/cplog.XXXXXX")"; export CP_LOG
HOST_BACKUP_DIR="" S3_BUCKET="b" S3_ENDPOINT="https://e" NEO4J_AUTH="neo4j/secret" \
  bash "${HERE}/../backup.sh" > "${WORK}/out.log" 2>&1
assert_success $? "S3-mode run succeeds"
if grep -q "s3://b/${TODAY}/neo4j.dump" "${CP_LOG}"; then assert_success 0 "uploaded as <date>/<db>.dump"; else assert_failure 0 "uploaded as <date>/<db>.dump"; fi
assert_eq "0" "$(find "${WORK}/backups" -name '*.dump' | wc -l | tr -d ' ')" "local dump removed after verified upload"
assert_eq "" "$(cat "${CTL_LOG}")" "no docker stop/start/update"
rm -rf "${WORK}"; rm -f "${CP_LOG}"; teardown_backup_stubs; teardown_stub_path

echo "test: S3 upload failure keeps the dump under today's date for retry and fails the job"
setup_stub_path; setup_backup_stubs
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bk.XXXXXX")"; mkdir -p "${WORK}/backups"; export BACKUP_ROOT="${WORK}/backups"
printf '"neo4j|/var/lib/neo4j/backups/neo4j-20261006-020000.dump|8|ok"\n' > "${ROWS_FILE}"
make_stub aws 'case "$1 $2" in "s3 cp") exit 1 ;; "s3 ls") exit 0 ;; "s3 rm") exit 0 ;; esac'
HOST_BACKUP_DIR="" S3_BUCKET="b" S3_ENDPOINT="https://e" NEO4J_AUTH="neo4j/secret" \
  bash "${HERE}/../backup.sh" > "${WORK}/out.log" 2>&1
assert_failure $? "upload failure => non-zero exit"
if [ -f "${WORK}/backups/${TODAY}/neo4j.dump" ]; then assert_success 0 "dump kept locally for retry"; else assert_failure 0 "dump kept locally for retry"; fi
rm -rf "${WORK}"; teardown_backup_stubs; teardown_stub_path

echo "test: a non-ok row fails the job but the other databases are still filed"
setup_stub_path; setup_backup_stubs
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bk.XXXXXX")"; mkdir -p "${WORK}/backups"; export BACKUP_ROOT="${WORK}/backups"
printf '"neo4j|/var/lib/neo4j/backups/neo4j-20261006-020000.dump|8|ok"\n"phlow|||failed: disk full"\n"uso|||skipped: not available"\n' > "${ROWS_FILE}"
HOST_BACKUP_DIR="${WORK}/backups" S3_BUCKET="" S3_ENDPOINT="" NEO4J_AUTH="neo4j/secret" \
  bash "${HERE}/../backup.sh" > "${WORK}/out.log" 2>&1
assert_failure $? "non-ok row => non-zero exit"
if [ -f "${WORK}/backups/${TODAY}/neo4j.dump" ]; then assert_success 0 "ok database still filed"; else assert_failure 0 "ok database still filed"; fi
if grep -q "FAILED: phlow (failed: disk full)" "${WORK}/out.log"; then assert_success 0 "failed row logged with its reason"; else assert_failure 0 "failed row logged with its reason"; fi
if grep -q "FAILED: uso (skipped: not available)" "${WORK}/out.log"; then assert_success 0 "skipped row logged as a failure"; else assert_failure 0 "skipped row logged as a failure"; fi
rm -rf "${WORK}"; teardown_backup_stubs; teardown_stub_path

echo "test: dump reported by the plugin but not visible in /backups is a failure"
setup_stub_path; setup_backup_stubs
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bk.XXXXXX")"; mkdir -p "${WORK}/backups"; export BACKUP_ROOT="${WORK}/backups"
make_stub docker 'case "$1" in exec) echo "row"; echo "\"neo4j|/var/lib/neo4j/backups/neo4j-20261006-020000.dump|8|ok\""; exit 0 ;; ps) echo "neo4j-neo4j-1" ;; esac'
HOST_BACKUP_DIR="${WORK}/backups" S3_BUCKET="" S3_ENDPOINT="" NEO4J_AUTH="neo4j/secret" \
  bash "${HERE}/../backup.sh" > "${WORK}/out.log" 2>&1
assert_failure $? "missing file => non-zero exit"
if grep -q "not visible at" "${WORK}/out.log"; then assert_success 0 "mount hint logged"; else assert_failure 0 "mount hint logged"; fi
rm -rf "${WORK}"; teardown_backup_stubs; teardown_stub_path

echo "test: backup.all() failure aborts with its output"
setup_stub_path; setup_backup_stubs
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bk.XXXXXX")"; mkdir -p "${WORK}/backups"; export BACKUP_ROOT="${WORK}/backups"
make_stub docker 'case "$1" in exec) echo "There is no procedure with the name backup.all" >&2; exit 1 ;; ps) echo "neo4j-neo4j-1" ;; esac'
HOST_BACKUP_DIR="${WORK}/backups" S3_BUCKET="" S3_ENDPOINT="" NEO4J_AUTH="neo4j/secret" \
  bash "${HERE}/../backup.sh" > "${WORK}/out.log" 2>&1
assert_failure $? "procedure failure => non-zero exit"
if grep -q "no procedure with the name backup.all" "${WORK}/out.log"; then assert_success 0 "procedure error surfaced in the log"; else assert_failure 0 "procedure error surfaced in the log"; fi
rm -rf "${WORK}"; teardown_backup_stubs; teardown_stub_path

echo "test: missing NEO4J_AUTH aborts"
setup_stub_path; setup_backup_stubs
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bk.XXXXXX")"; mkdir -p "${WORK}/backups"; export BACKUP_ROOT="${WORK}/backups"
HOST_BACKUP_DIR="${WORK}/backups" S3_BUCKET="" S3_ENDPOINT="" NEO4J_AUTH="" \
  bash "${HERE}/../backup.sh" > "${WORK}/out.log" 2>&1
assert_failure $? "no credentials => non-zero exit"
rm -rf "${WORK}"; teardown_backup_stubs; teardown_stub_path

echo "test: not configured (no HOST_BACKUP_DIR, no S3) skips quietly"
setup_stub_path; setup_backup_stubs
HOST_BACKUP_DIR="" S3_BUCKET="" S3_ENDPOINT="" NEO4J_AUTH="neo4j/secret" bash "${HERE}/../backup.sh" >/dev/null 2>&1
assert_success $? "skip => exit 0"
teardown_backup_stubs; teardown_stub_path

finish
