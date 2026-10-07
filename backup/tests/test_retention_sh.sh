#!/bin/bash
# Tests for retention.sh (calendar windows, complete dates only). Bash 3.2 compatible.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/helpers.sh"

echo "syntax: retention.sh"
bash -n "${HERE}/../retention.sh"; assert_success $? "retention.sh parses"

# Pin "today" to 2026-10-07 through a date stub (other formats go to the real date).
pin_today() { make_stub date 'if [ "${1:-}" = "+%Y-%m-%d" ]; then echo 2026-10-07; else exec /bin/date "$@"; fi'; }

# mkdate <date> <db>...: a local date folder holding <db>.dump for each db
mkdate() { local d="$1"; shift; mkdir -p "${WORK}/${d}"; local db; for db in "$@"; do printf x > "${WORK}/${d}/${db}.dump"; done; }
run_local() { BACKUP_ROOT="${WORK}" S3_BUCKET="" S3_ENDPOINT="" bash "${HERE}/../retention.sh" > "${WORK}/out.log" 2>&1; }
logged() { if grep -q -- "$1" "${WORK}/out.log"; then assert_success 0 "$2"; else assert_failure 0 "$2"; echo "    --- out.log:"; sed 's/^/    /' "${WORK}/out.log"; fi; }
exists() { if [ -d "${WORK}/$1" ]; then assert_success 0 "$2"; else assert_failure 0 "$2"; fi; }
gone() { if [ -d "${WORK}/$1" ]; then assert_failure 0 "$2"; else assert_success 0 "$2"; fi; }

echo "test: local mode keeps the calendar window, removes older and incomplete dates"
setup_stub_path; pin_today
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ret.XXXXXX")"
mkdate 2026-10-07 neo4j system
mkdate 2026-10-06 neo4j system
mkdate 2026-10-05 neo4j            # incomplete, inside the window
mkdate 2026-10-01 neo4j system     # complete, outside daily=3
BACKUP_DATABASES="neo4j system" BACKUP_RETENTION="daily=3" run_local
assert_success $? "local run succeeds"
exists 2026-10-07 "today kept"; exists 2026-10-06 "yesterday kept"
gone 2026-10-05 "incomplete date removed even inside the window"
gone 2026-10-01 "date outside the window removed"
logged "Keeping local: 2026-10-07 (daily)" "log names the rule"
logged "Removing local: 2026-10-05 (incomplete, missing: system)" "log names the missing database"
rm -rf "${WORK}"; teardown_stub_path

echo "test: local mode ignores the logs/ folder of upload debug logs"
setup_stub_path; pin_today
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ret.XXXXXX")"
mkdate 2026-10-07 neo4j
mkdir -p "${WORK}/logs/2026-01-01"; printf x > "${WORK}/logs/2026-01-01/neo4j-upload.log"
BACKUP_DATABASES="neo4j" BACKUP_RETENTION="daily=3" run_local
assert_success $? "local run succeeds"
exists logs/2026-01-01 "logs/ and its date folders untouched"
if grep -q "logs" "${WORK}/out.log"; then assert_failure 0 "logs/ not mentioned"; else assert_success 0 "logs/ not mentioned"; fi
rm -rf "${WORK}"; teardown_stub_path

echo "test: S3 production case: daily=14 on 2026-10-07"
setup_stub_path; pin_today
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ret.XXXXXX")"
LISTING="${WORK}/listing"
for d in 2026-08-01 2026-09-01 2026-09-13 2026-09-20 2026-09-27 2026-09-29 2026-09-30 2026-10-01 2026-10-02 2026-10-03 2026-10-04 2026-10-05 2026-10-06; do
  for db in neo4j system avvocato360; do echo "${d} 02:00:01       1234 ${d}/${db}.dump" >> "${LISTING}"; done
done
echo "2026-10-07 02:00:01       1234 2026-10-07/neo4j.dump" >> "${LISTING}"
echo "2026-10-07 02:00:01       1234 2026-10-07/system.dump" >> "${LISTING}"
make_stub aws '
case "$1 $2" in
  "s3 ls") echo "$@" >> "${LS_LOG}"; cat "${LISTING}"; exit 0 ;;
  "s3 rm") echo "$3" >> "${RM_LOG}"; exit 0 ;;
esac'
export LISTING; RM_LOG="${WORK}/rm.log"; LS_LOG="${WORK}/ls.log"; : > "${RM_LOG}"; export RM_LOG LS_LOG
BACKUP_ROOT="${WORK}" S3_BUCKET="b" S3_ENDPOINT="https://e" BACKUP_RETENTION="daily=14" BACKUP_DATABASES="neo4j system avvocato360" \
  bash "${HERE}/../retention.sh" > "${WORK}/out.log" 2>&1
assert_success $? "S3 run succeeds"
assert_eq "s3://b/2026-08-01/ s3://b/2026-09-01/ s3://b/2026-09-13/ s3://b/2026-09-20/ s3://b/2026-10-07/ " \
  "$(sort "${RM_LOG}" | tr '\n' ' ')" "08-01, 09-01, 09-13, 09-20 and incomplete 10-07 removed"
assert_eq "1" "$(grep -c -- "--recursive" "${LS_LOG}")" "one recursive listing of the bucket"
logged "Removing S3: 2026-10-07 (incomplete, missing: avvocato360)" "incomplete date explained"
logged "Keeping S3: 2026-09-27 (daily)" "oldest date in the window kept"
rm -rf "${WORK}"; teardown_stub_path

echo "test: policy that would leave no complete backup deletes nothing and fails"
setup_stub_path; pin_today
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ret.XXXXXX")"
mkdate 2026-09-01 neo4j
mkdate 2026-08-01 neo4j
BACKUP_DATABASES="neo4j" BACKUP_RETENTION="daily=3" run_local
assert_failure $? "zero survivors => non-zero exit"
exists 2026-09-01 "nothing deleted (09-01)"; exists 2026-08-01 "nothing deleted (08-01)"
logged "would leave no complete" "error explains itself"
rm -rf "${WORK}"; teardown_stub_path

echo "test: no complete date at all deletes nothing and fails"
setup_stub_path; pin_today
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ret.XXXXXX")"
mkdate 2026-10-07 neo4j
mkdate 2026-10-06 neo4j
BACKUP_DATABASES="neo4j system" BACKUP_RETENTION="daily=7" run_local
assert_failure $? "no complete date => non-zero exit"
exists 2026-10-07 "nothing deleted (10-07)"; exists 2026-10-06 "nothing deleted (10-06)"
rm -rf "${WORK}"; teardown_stub_path

echo "test: standalone run queries the database list itself"
setup_stub_path; pin_today
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ret.XXXXXX")"
mkdate 2026-10-07 neo4j system
mkdate 2026-10-06 neo4j
make_stub docker 'case "$1" in exec) echo row; echo "\"neo4j|online\""; echo "\"system|online\"" ;; ps) echo neo4j-neo4j-1 ;; esac'
( unset BACKUP_DATABASES; NEO4J_AUTH="neo4j/secret" BACKUP_RETENTION="daily=7" run_local )
assert_success $? "standalone run succeeds"
exists 2026-10-07 "complete date kept"
gone 2026-10-06 "date without system.dump removed"
rm -rf "${WORK}"; teardown_stub_path

echo "test: database list unavailable deletes nothing and fails"
setup_stub_path; pin_today
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ret.XXXXXX")"
mkdate 2026-10-07 neo4j
mkdate 2026-01-01 neo4j
make_stub docker 'case "$1" in exec) echo "Connection refused" >&2; exit 1 ;; ps) echo neo4j-neo4j-1 ;; esac'
( unset BACKUP_DATABASES; NEO4J_AUTH="neo4j/secret" BACKUP_RETENTION="daily=7" run_local )
assert_failure $? "list failure => non-zero exit"
exists 2026-01-01 "nothing deleted"
logged "could not list databases.*Nothing deleted" "error explains itself"
( unset BACKUP_DATABASES NEO4J_AUTH; BACKUP_RETENTION="daily=7" run_local )
assert_failure $? "no list and no credentials => non-zero exit"
exists 2026-01-01 "still nothing deleted"
rm -rf "${WORK}"; teardown_stub_path

echo "test: S3 listing failure deletes nothing and fails"
setup_stub_path; pin_today
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ret.XXXXXX")"
make_stub aws 'case "$1 $2" in "s3 ls") echo "Could not connect" >&2; exit 1 ;; "s3 rm") echo "$3" >> "${RM_LOG}" ;; esac'
RM_LOG="${WORK}/rm.log"; : > "${RM_LOG}"; export RM_LOG
BACKUP_ROOT="${WORK}" S3_BUCKET="b" S3_ENDPOINT="https://e" BACKUP_RETENTION="daily=7" BACKUP_DATABASES="neo4j" \
  bash "${HERE}/../retention.sh" > "${WORK}/out.log" 2>&1
assert_failure $? "listing failure => non-zero exit"
assert_eq "" "$(cat "${RM_LOG}")" "nothing deleted"
rm -rf "${WORK}"; teardown_stub_path

echo "test: invalid BACKUP_RETENTION deletes nothing and fails"
setup_stub_path; pin_today
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ret.XXXXXX")"
mkdate 2026-10-07 neo4j; mkdate 2026-01-01 neo4j
BACKUP_DATABASES="neo4j" BACKUP_RETENTION="daily=0" run_local
assert_failure $? "invalid policy => non-zero exit"
exists 2026-01-01 "nothing deleted"
logged "Nothing deleted" "error explains itself"
rm -rf "${WORK}"; teardown_stub_path

echo "test: unset BACKUP_RETENTION uses the default daily=7,weekly=4,monthly=12"
setup_stub_path; pin_today
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ret.XXXXXX")"
mkdate 2026-10-07 neo4j
( unset BACKUP_RETENTION; BACKUP_DATABASES="neo4j" run_local )
assert_success $? "default run succeeds"
logged "Policy: daily=7,weekly=4,monthly=12" "default policy logged"
rm -rf "${WORK}"; teardown_stub_path

# Regression guard: `aws s3 rm` rejects --no-progress (only cp/mv/sync accept it).
# Any `aws s3 rm` must use --quiet, or S3-side cleanup silently fails.
echo "static: no 'aws s3 rm' uses --no-progress"
BAD=$(grep -rn -A3 'aws s3 rm' "${HERE}/../lib.sh" "${HERE}/../retention.sh" "${HERE}/../backup.sh" "${HERE}/../restore.sh" 2>/dev/null | grep -c -- '--no-progress')
assert_eq "0" "${BAD}" "no 'aws s3 rm ... --no-progress' anywhere"

finish
