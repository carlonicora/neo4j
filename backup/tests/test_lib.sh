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

echo "test: retention_period"
assert_eq "$(retention_period weekly 2026-10-05)" "$(retention_period weekly 2026-10-11)" "Monday and Sunday share a week"
assert_eq "1" "$(( $(retention_period weekly 2026-10-05) - $(retention_period weekly 2026-10-04) ))" "Sunday before Monday is the previous week"
assert_eq "1" "$(( $(retention_period monthly 2027-01-01) - $(retention_period monthly 2026-12-31) ))" "December to January is one month"
assert_eq "2026" "$(retention_period yearly 2026-10-06)" "yearly period"
assert_eq "1" "$(( $(retention_period daily 2026-03-01) - $(retention_period daily 2026-02-28) ))" "daily period is the day"

echo "test: retention_validate"
retention_validate "daily=7,weekly=4,monthly=12" 2>/dev/null; assert_success $? "default policy valid"
retention_validate "daily=14" 2>/dev/null; assert_success $? "single rule valid"
retention_validate "" 2>/dev/null; assert_failure $? "empty rejected"
retention_validate "hourly=3" 2>/dev/null; assert_failure $? "unknown rule rejected"
retention_validate "daily=x" 2>/dev/null; assert_failure $? "non-number rejected"
retention_validate "daily=7,daily=3" 2>/dev/null; assert_failure $? "duplicate rule rejected"
retention_validate "daily=0,weekly=0" 2>/dev/null; assert_failure $? "all-zero rejected"

echo "test: retention_keep_dates daily=14 is the last 14 calendar days (production case)"
# today 2026-10-07 => window 2026-09-24..2026-10-07. 10-07 is incomplete, so it is not passed in.
KEEP=$(retention_keep_dates "daily=14" 2026-10-07 2026-08-01 2026-09-01 2026-09-13 2026-09-20 2026-09-27 2026-09-29 2026-09-30 \
  2026-10-01 2026-10-02 2026-10-03 2026-10-04 2026-10-05 2026-10-06 | awk '{print $1}' | sort | tr '\n' ' ')
assert_eq "2026-09-27 2026-09-29 2026-09-30 2026-10-01 2026-10-02 2026-10-03 2026-10-04 2026-10-05 2026-10-06 " "${KEEP}" "08-01, 09-01, 09-13, 09-20 fall outside the window"

echo "test: retention_keep_dates daily window edge"
KEEP=$(retention_keep_dates "daily=3" 2026-10-07 2026-10-07 2026-10-05 2026-10-04 | awk '{print $1}' | sort | tr '\n' ' ')
assert_eq "2026-10-05 2026-10-07 " "${KEEP}" "daily=3 on 10-07 covers 10-05..10-07 only"

echo "test: retention_keep_dates weekly is calendar weeks, current one included"
# today Wed 2026-10-07. Weeks: 10-05..11 (current), 09-28..10-04, 09-21..27, 09-14..20.
KEEP=$(retention_keep_dates "weekly=3" 2026-10-07 2026-10-06 2026-10-05 2026-10-01 2026-09-29 2026-09-15 | sort | tr '\n' '|')
assert_eq "2026-10-01 weekly|2026-10-06 weekly|" "${KEEP}" "newest per week; empty week 09-21 still uses up a slot, 09-15 is 4 weeks back"

echo "test: retention_keep_dates monthly is calendar months, current one included"
KEEP=$(retention_keep_dates "monthly=3" 2026-10-07 2026-10-02 2026-09-30 2026-09-01 2026-07-31 2026-06-30 | awk '{print $1}' | sort | tr '\n' ' ')
assert_eq "2026-09-30 2026-10-02 " "${KEEP}" "Oct, Sep kept; Aug has none; Jul is 3 months back"

echo "test: retention_keep_dates yearly"
KEEP=$(retention_keep_dates "yearly=2" 2026-10-07 2026-01-05 2025-12-31 2025-06-01 2024-12-31 | awk '{print $1}' | sort | tr '\n' ' ')
assert_eq "2025-12-31 2026-01-05 " "${KEEP}" "newest of this year and last year"

echo "test: retention_keep_dates rules combine, first rule named"
KEEP=$(retention_keep_dates "daily=2,weekly=2" 2026-10-07 2026-10-07 2026-10-06 2026-10-05 2026-10-01 2026-09-30 | sort | tr '\n' '|')
assert_eq "2026-10-01 weekly|2026-10-06 daily|2026-10-07 daily|" "${KEEP}" "two days + newest of last week; current week already kept by daily"

echo "test: retention_keep_dates last=N"
assert_eq "2026-10-06 last" "$(retention_keep_dates "last=1" 2026-10-07 2026-10-01 2026-10-06 2026-10-04)" "newest only, regardless of input order"
KEEP=$(retention_keep_dates "last=2" 2026-10-07 2025-01-01 2024-01-01 2023-01-01 | awk '{print $1}' | tr '\n' ' ')
assert_eq "2025-01-01 2024-01-01 " "${KEEP}" "last ignores how old the dates are"

echo "test: retention_keep_dates nothing in window => no output"
assert_eq "" "$(retention_keep_dates "daily=3" 2026-10-07 2026-09-01 2026-08-01)" "all too old => empty (caller refuses to delete)"

echo "test: retention_keep_dates invalid policy keeps nothing and fails"
OUT=$(retention_keep_dates "bogus" 2026-10-07 2026-10-06 2>/dev/null); RC=$?
assert_failure ${RC} "bad policy => rc 1"
assert_eq "" "${OUT}" "bad policy => no output"

echo "test: missing_databases"
assert_eq "" "$(missing_databases "neo4j.dump system.dump avvocato360.dump" "neo4j system avvocato360")" "all present => complete"
assert_eq "avvocato360" "$(missing_databases "neo4j.dump system.dump" "neo4j system avvocato360")" "missing one is named"
assert_eq "neo4j system" "$(missing_databases ". other.dump" "neo4j system")" "empty date misses all"

echo "test: estimate_dump_size sums store and transaction log"
DATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/data.XXXXXX")"
mkdir -p "${DATA_DIR}/databases/neo4j" "${DATA_DIR}/transactions/neo4j"
dd if=/dev/zero of="${DATA_DIR}/databases/neo4j/store" bs=1024 count=64 2>/dev/null
dd if=/dev/zero of="${DATA_DIR}/transactions/neo4j/log" bs=1024 count=32 2>/dev/null
EST=$(estimate_dump_size neo4j); RC=$?
assert_success ${RC} "estimate succeeds"
if [ "${EST}" -ge $((96 * 1024)) ]; then assert_success 0 "estimate covers store + transactions (${EST})"; else assert_failure 0 "estimate covers store + transactions (${EST})"; fi
EST=$(estimate_dump_size nosuchdb); RC=$?
assert_failure ${RC} "missing store => rc 1"
assert_eq "0" "${EST}" "missing store => 0"
rm -rf "${DATA_DIR}"; DATA_DIR=/data

echo "test: database_status_rows parses SHOW DATABASES"
setup_stub_path
NEO4J_AUTH="neo4j/secret"
make_stub docker 'echo "$@" > "${ARGS_LOG}"; echo row; echo "\"neo4j|online\""; echo "\"system|online\""; echo "\"old|offline\""'
ARGS_LOG="$(mktemp "${TMPDIR:-/tmp}/args.XXXXXX")"; export ARGS_LOG
assert_eq "neo4j|online system|online old|offline" "$(database_status_rows c1 | tr '\n' ' ' | sed 's/ $//')" "one name|status per database"
if grep -q -- "-d system" "${ARGS_LOG}" && grep -q "SHOW DATABASES" "${ARGS_LOG}"; then assert_success 0 "queries system with SHOW DATABASES"; else assert_failure 0 "queries system with SHOW DATABASES"; fi
rm -f "${ARGS_LOG}"; teardown_stub_path

echo "test: load_database_list falls back to the Compose v1 name, reports errors"
setup_stub_path
NEO4J_AUTH="neo4j/secret"
make_stub docker 'if [ "$2" = "neo4j_neo4j_1" ]; then echo row; echo "\"neo4j|online\""; else echo "No such container: $2" >&2; exit 1; fi'
NEO4J_CONTAINER="neo4j-neo4j-1"
load_database_list; assert_success $? "fallback container works"
assert_eq "neo4j_neo4j_1" "${NEO4J_CONTAINER}" "container switched to the fallback"
make_stub docker 'echo "Connection refused" >&2; exit 1'
NEO4J_CONTAINER="neo4j-neo4j-1"
load_database_list; assert_failure $? "unreachable Neo4j => rc 1"
if printf '%s' "${DB_LIST_ERROR}" | grep -q "Connection refused"; then assert_success 0 "error carries cypher-shell output"; else assert_failure 0 "error carries cypher-shell output"; fi
teardown_stub_path

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

echo "test: discard_s3_object removes the object and aborts its multipart uploads"
setup_stub_path
S3_BUCKET="b" S3_ENDPOINT="https://e"
make_stub aws '
echo "$@" >> "${AWS_LOG}"
case "$1 $2" in
  "s3api list-multipart-uploads") printf "UP1\tUP2\n" ;;
esac
exit 0'
AWS_LOG="$(mktemp "${TMPDIR:-/tmp}/awslog.XXXXXX")"; export AWS_LOG
discard_s3_object 2026-10-07/neo4j.dump
if grep -q "s3 rm s3://b/2026-10-07/neo4j.dump" "${AWS_LOG}"; then assert_success 0 "object removed"; else assert_failure 0 "object removed"; fi
assert_eq "2" "$(grep -c "abort-multipart-upload --bucket b --key 2026-10-07/neo4j.dump" "${AWS_LOG}")" "both open uploads aborted"
make_stub aws 'echo "$@" >> "${AWS_LOG}"; case "$1 $2" in "s3api list-multipart-uploads") echo None ;; esac; exit 0'
: > "${AWS_LOG}"
discard_s3_object 2026-10-07/neo4j.dump
assert_eq "0" "$(grep -c "abort-multipart-upload" "${AWS_LOG}")" "None => nothing to abort"
rm -f "${AWS_LOG}"; teardown_stub_path

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
