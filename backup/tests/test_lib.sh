#!/bin/bash
# Runnable test suite for backup/lib.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/helpers.sh"
source "${HERE}/../lib.sh"

echo "test: s3_configured"
S3_BUCKET="" S3_ENDPOINT="" ; if s3_configured; then assert_failure 0 "unset => not configured"; else assert_success 0 "unset => not configured"; fi
S3_BUCKET="b" S3_ENDPOINT="https://e" ; if s3_configured; then assert_success 0 "both set => configured"; else assert_failure 0 "both set => configured"; fi
S3_BUCKET="b" S3_ENDPOINT="" ; if s3_configured; then assert_failure 0 "endpoint missing => not configured"; else assert_success 0 "endpoint missing => not configured"; fi
S3_BUCKET="" S3_ENDPOINT="https://e" ; if s3_configured; then assert_failure 0 "bucket missing => not configured"; else assert_success 0 "bucket missing => not configured"; fi

echo "test: NEO4J_ADMIN_IMAGE default"
assert_eq "neo4j/neo4j-admin:5.26-community-bullseye" \
  "$(unset NEO4J_ADMIN_IMAGE; source "${HERE}/../lib.sh"; echo "${NEO4J_ADMIN_IMAGE}")" \
  "image default set"

echo "test: write_backup_env_file quotes values so source cannot execute them"
ENVF="$(mktemp "${TMPDIR:-/tmp}/envf.XXXXXX")"
( export NEO4J_AUTH='neo4j/pa ss;ad min$x"y'"'"'z' S3_BUCKET='b' UNRELATED='nope'; write_backup_env_file "${ENVF}" )
assert_success $? "writes without error"
( set -a; source "${ENVF}"; set +a; [ "${NEO4J_AUTH}" = 'neo4j/pa ss;ad min$x"y'"'"'z' ] ); assert_success $? "password with space ; \$ quotes survives source"
( set -a; source "${ENVF}"; set +a; [ "${S3_BUCKET}" = "b" ] ); assert_success $? "plain value survives source"
if grep -q UNRELATED "${ENVF}"; then assert_failure 0 "unrelated variables excluded"; else assert_success 0 "unrelated variables excluded"; fi
assert_eq "600" "$(stat -f %Lp "${ENVF}" 2>/dev/null || stat -c %a "${ENVF}")" "file is 0600 (holds the password)"
rm -f "${ENVF}"

echo "test: date_to_days"
assert_eq "0" "$(date_to_days 1970-01-01)" "epoch day is 0"
assert_eq "20732" "$(date_to_days 2026-10-06)" "2026-10-06 is day 20732 (a Tuesday)"
assert_eq "1" "$(( $(date_to_days 2024-03-01) - $(date_to_days 2024-02-29) ))" "leap day handled"

echo "test: retention_bucket"
assert_eq "$(retention_bucket weekly 2026-10-05)" "$(retention_bucket weekly 2026-10-11)" "Monday and Sunday share a week"
if [ "$(retention_bucket weekly 2026-10-04)" != "$(retention_bucket weekly 2026-10-05)" ]; then assert_success 0 "Sunday before Monday is another week"; else assert_failure 0 "Sunday before Monday is another week"; fi
assert_eq "2026-10" "$(retention_bucket monthly 2026-10-06)" "monthly bucket"
assert_eq "2026" "$(retention_bucket yearly 2026-10-06)" "yearly bucket"

echo "test: retention_validate"
retention_validate "daily=7,weekly=4,monthly=12" 2>/dev/null; assert_success $? "default policy valid"
retention_validate "daily=14" 2>/dev/null; assert_success $? "single rule valid"
retention_validate "" 2>/dev/null; assert_failure $? "empty rejected"
retention_validate "hourly=3" 2>/dev/null; assert_failure $? "unknown rule rejected"
retention_validate "daily=x" 2>/dev/null; assert_failure $? "non-number rejected"
retention_validate "daily=7,daily=3" 2>/dev/null; assert_failure $? "duplicate rule rejected"
retention_validate "daily=0,weekly=0" 2>/dev/null; assert_failure $? "all-zero rejected"

echo "test: retention_keep_dates daily=14 keeps the 14 newest days"
DATES=""; for i in $(seq 1 20); do DATES="${DATES} 2026-09-$(printf %02d $i)"; done
# shellcheck disable=SC2086
KEEP=$(retention_keep_dates "daily=14" ${DATES} | awk '{print $1}' | sort | tr '\n' ' ')
assert_eq "2026-09-07 2026-09-08 2026-09-09 2026-09-10 2026-09-11 2026-09-12 2026-09-13 2026-09-14 2026-09-15 2026-09-16 2026-09-17 2026-09-18 2026-09-19 2026-09-20 " "${KEEP}" "days 7..20 kept"

echo "test: retention_keep_dates daily=3,weekly=2 (borg semantics: weeks already represented by daily keepers do not count)"
KEEP=$(retention_keep_dates "daily=3,weekly=2" 2026-10-06 2026-10-05 2026-10-04 2026-10-03 2026-10-02 2026-09-28 2026-09-21 2026-09-14 | sort | tr '\n' '|')
assert_eq "2026-09-14 weekly|2026-09-21 weekly|2026-10-04 daily|2026-10-05 daily|2026-10-06 daily|" "${KEEP}" "3 daily + 2 older weeks; 10-03, 10-02, 09-28 deleted"

echo "test: retention_keep_dates skips periods without backups"
KEEP=$(retention_keep_dates "daily=3" 2026-10-06 2026-10-01 2026-09-20 | awk '{print $1}' | sort | tr '\n' ' ')
assert_eq "2026-09-20 2026-10-01 2026-10-06 " "${KEEP}" "three real backups kept despite gaps"

echo "test: retention_keep_dates monthly keeps newest per month"
KEEP=$(retention_keep_dates "monthly=2" 2026-10-06 2026-10-01 2026-09-30 2026-08-15 | awk '{print $1}' | sort | tr '\n' ' ')
assert_eq "2026-09-30 2026-10-06 " "${KEEP}" "newest of the last two months"

echo "test: retention_keep_dates last=1"
assert_eq "2026-10-06 last" "$(retention_keep_dates "last=1" 2026-10-01 2026-10-06 2026-10-04)" "newest only, regardless of input order"

echo "test: retention_keep_dates invalid policy keeps nothing and fails"
OUT=$(retention_keep_dates "bogus" 2026-10-06 2>/dev/null); RC=$?
assert_failure ${RC} "bad policy => rc 1"
assert_eq "" "${OUT}" "bad policy => no output"

echo "test: s3_object_size"
setup_stub_path
S3_BUCKET="b" S3_ENDPOINT="https://e"
make_stub aws 'if [ "$1 $2" = "s3 ls" ]; then echo "2026-06-16 02:00:01      8 neo4j.dump"; fi'
assert_eq "8" "$(s3_object_size 2026-06-16/neo4j.dump)" "parses size column"
teardown_stub_path

echo "test: s3_object_size absent key"
setup_stub_path
S3_BUCKET="b" S3_ENDPOINT="https://e"
make_stub aws 'exit 0'   # nothing listed
assert_eq "" "$(s3_object_size 2026-06-16/missing.dump)" "absent key => empty"
teardown_stub_path

echo "test: upload_dump_to_s3 success (sizes match)"
setup_stub_path
S3_BUCKET="b" S3_ENDPOINT="https://e"
DUMP="$(mktemp "${TMPDIR:-/tmp}/dump.XXXXXX")"; printf DUMPDATA > "${DUMP}"   # 8 bytes
make_stub aws '
case "$1 $2" in
  "s3 cp") echo "$@" >> "${CP_LOG}"; exit 0 ;;
  "s3 ls") echo "2026-06-16 02:00:01      8 neo4j.dump"; exit 0 ;;
  "s3 rm") echo "$@" >> "${RM_LOG}"; exit 0 ;;
esac'
CP_LOG="$(mktemp "${TMPDIR:-/tmp}/cplog.XXXXXX")"; export CP_LOG
RM_LOG="$(mktemp "${TMPDIR:-/tmp}/rmlog.XXXXXX")"; export RM_LOG
upload_dump_to_s3 "${DUMP}" neo4j 2026-06-16; assert_success $? "matching sizes => success"
if grep -q "s3://b/2026-06-16/neo4j.dump" "${CP_LOG}"; then assert_success 0 "uploaded as <date>/<db>.dump"; else assert_failure 0 "uploaded as <date>/<db>.dump"; fi
assert_eq "" "$(cat "${RM_LOG}")" "no deletion on success"
if [ -f "${DUMP}" ]; then assert_success 0 "local file untouched"; else assert_failure 0 "local file untouched"; fi
rm -f "${CP_LOG}" "${RM_LOG}" "${DUMP}"; teardown_stub_path

echo "test: upload_dump_to_s3 size mismatch deletes partial"
setup_stub_path
S3_BUCKET="b" S3_ENDPOINT="https://e"
DUMP="$(mktemp "${TMPDIR:-/tmp}/dump.XXXXXX")"; printf DUMPDATA > "${DUMP}"
make_stub aws '
case "$1 $2" in
  "s3 cp") exit 0 ;;
  "s3 ls") echo "2026-06-16 02:00:01      3 neo4j.dump"; exit 0 ;;
  "s3 rm") echo "$@" >> "${RM_LOG}"; exit 0 ;;
esac'
RM_LOG="$(mktemp "${TMPDIR:-/tmp}/rmlog.XXXXXX")"; export RM_LOG
upload_dump_to_s3 "${DUMP}" neo4j 2026-06-16; assert_failure $? "size mismatch => failure"
if grep -q "neo4j.dump" "${RM_LOG}"; then assert_success 0 "partial object deleted"; else assert_failure 0 "partial object deleted"; fi
rm -f "${RM_LOG}" "${DUMP}"; teardown_stub_path

echo "test: upload_dump_to_s3 upload failure deletes partial"
setup_stub_path
S3_BUCKET="b" S3_ENDPOINT="https://e"
DUMP="$(mktemp "${TMPDIR:-/tmp}/dump.XXXXXX")"; printf DUMPDATA > "${DUMP}"
make_stub aws '
case "$1 $2" in
  "s3 cp") exit 1 ;;
  "s3 ls") echo "2026-06-16 02:00:01      8 neo4j.dump"; exit 0 ;;
  "s3 rm") echo "$@" >> "${RM_LOG}"; exit 0 ;;
esac'
RM_LOG="$(mktemp "${TMPDIR:-/tmp}/rmlog.XXXXXX")"; export RM_LOG
upload_dump_to_s3 "${DUMP}" neo4j 2026-06-16; assert_failure $? "upload failure => failure"
if grep -q "neo4j.dump" "${RM_LOG}"; then assert_success 0 "partial deleted on upload failure"; else assert_failure 0 "partial deleted on upload failure"; fi
rm -f "${RM_LOG}" "${DUMP}"; teardown_stub_path

echo "test: drain_local_backlog removes verified dir"
setup_stub_path
S3_BUCKET="b" S3_ENDPOINT="https://e"
BACKUP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/backups.XXXXXX")"
mkdir -p "${BACKUP_ROOT}/2026-03-10"; printf x > "${BACKUP_ROOT}/2026-03-10/neo4j.dump"
make_stub aws '
case "$1 $2" in
  "s3 cp") exit 0 ;;
  "s3 ls") echo "2026-03-10 00:00:00      1 neo4j.dump"; exit 0 ;;
esac'
drain_local_backlog
if [ -d "${BACKUP_ROOT}/2026-03-10" ]; then assert_failure 0 "verified dir removed"; else assert_success 0 "verified dir removed"; fi
rm -rf "${BACKUP_ROOT}"; teardown_stub_path

echo "test: drain_local_backlog keeps unverified dir"
setup_stub_path
S3_BUCKET="b" S3_ENDPOINT="https://e"
BACKUP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/backups.XXXXXX")"
mkdir -p "${BACKUP_ROOT}/2026-03-11"; printf x > "${BACKUP_ROOT}/2026-03-11/neo4j.dump"
make_stub aws '
case "$1 $2" in
  "s3 cp") exit 1 ;;
  "s3 ls") exit 0 ;;
esac'
drain_local_backlog
if [ -d "${BACKUP_ROOT}/2026-03-11" ]; then assert_success 0 "failed upload keeps dir"; else assert_failure 0 "failed upload keeps dir"; fi
rm -rf "${BACKUP_ROOT}"; teardown_stub_path

echo "test: drain_local_backlog keeps dir on count mismatch"
setup_stub_path
S3_BUCKET="b" S3_ENDPOINT="https://e"
BACKUP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/backups.XXXXXX")"
mkdir -p "${BACKUP_ROOT}/2026-03-12"
printf x > "${BACKUP_ROOT}/2026-03-12/neo4j.dump"
printf y > "${BACKUP_ROOT}/2026-03-12/system.dump"   # 2 local files
make_stub aws '
case "$1 $2" in
  "s3 cp") exit 0 ;;
  "s3 ls") echo "2026-03-12 00:00:00      1 neo4j.dump"; exit 0 ;;   # only 1 object < 2 files
esac'
drain_local_backlog
if [ -d "${BACKUP_ROOT}/2026-03-12" ]; then assert_success 0 "count mismatch keeps dir"; else assert_failure 0 "count mismatch keeps dir"; fi
rm -rf "${BACKUP_ROOT}"; teardown_stub_path

echo "test: list_s3_databases"
setup_stub_path
S3_BUCKET="b" S3_ENDPOINT="https://e"
make_stub aws '
if [ "$1 $2" = "s3 ls" ]; then
  echo "2026-06-16 02:00:01      8 neo4j.dump"
  echo "2026-06-16 02:00:02      9 system.dump"
fi'
OUT="$(list_s3_databases 2026-06-16 | tr "\n" "," )"
assert_eq "neo4j,system," "${OUT}" "lists db names without .dump"
teardown_stub_path

echo "test: stream_load_from_s3 success"
setup_stub_path
S3_BUCKET="b" S3_ENDPOINT="https://e" HOST_DATA_DIR="/host/data"
make_stub aws 'if [ "$1 $2" = "s3 cp" ]; then printf "DUMPDATA"; exit 0; fi'
make_stub docker 'if [ "$1" = run ]; then cat >/dev/null; exit 0; fi'
stream_load_from_s3 neo4j 2026-06-16; assert_success $? "load streams from S3"
teardown_stub_path

echo "test: stream_load_from_s3 load failure"
setup_stub_path
S3_BUCKET="b" S3_ENDPOINT="https://e" HOST_DATA_DIR="/host/data"
make_stub aws 'if [ "$1 $2" = "s3 cp" ]; then printf "DUMPDATA"; exit 0; fi'
make_stub docker 'if [ "$1" = run ]; then cat >/dev/null; exit 1; fi'
stream_load_from_s3 neo4j 2026-06-16; assert_failure $? "load failure => rc 1"
teardown_stub_path

finish
