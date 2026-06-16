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

echo "test: estimate_dump_size"
setup_stub_path
make_stub du 'echo "100	$2"'
DATA_DIR="/data"
assert_eq "102400" "$(estimate_dump_size neo4j)" "100KB => 102400 bytes"
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

echo "test: stream_dump_to_s3 success (bytes match)"
setup_stub_path
S3_BUCKET="b" S3_ENDPOINT="https://e" HOST_DATA_DIR="/host/data" DATA_DIR="/data"
make_stub du 'echo "1	$2"'
make_stub docker 'if [ "$1" = run ]; then printf "DUMPDATA"; fi'   # 8 bytes
make_stub aws '
case "$1 $2" in
  "s3 cp") cat >/dev/null; exit 0 ;;
  "s3 ls") echo "2026-06-16 02:00:01      8 neo4j.dump"; exit 0 ;;
  "s3 rm") echo "$@" >> "${RM_LOG}"; exit 0 ;;
esac'
RM_LOG="$(mktemp "${TMPDIR:-/tmp}/rmlog.XXXXXX")"; export RM_LOG
stream_dump_to_s3 neo4j 2026-06-16; assert_success $? "matching bytes => success"
assert_eq "" "$(cat "${RM_LOG}")" "no partial deletion on success"
rm -f "${RM_LOG}"; teardown_stub_path

echo "test: stream_dump_to_s3 mismatch deletes partial"
setup_stub_path
S3_BUCKET="b" S3_ENDPOINT="https://e" HOST_DATA_DIR="/host/data" DATA_DIR="/data"
make_stub du 'echo "1	$2"'
make_stub docker 'if [ "$1" = run ]; then printf "DUMPDATA"; fi'   # 8 bytes
make_stub aws '
case "$1 $2" in
  "s3 cp") cat >/dev/null; exit 0 ;;
  "s3 ls") echo "2026-06-16 02:00:01      4 neo4j.dump"; exit 0 ;;
  "s3 rm") echo "$@" >> "${RM_LOG}"; exit 0 ;;
esac'
RM_LOG="$(mktemp "${TMPDIR:-/tmp}/rmlog.XXXXXX")"; export RM_LOG
stream_dump_to_s3 neo4j 2026-06-16; assert_failure $? "size mismatch => failure"
if grep -q "neo4j.dump" "${RM_LOG}"; then assert_success 0 "partial object deleted"; else assert_failure 0 "partial object deleted"; fi
rm -f "${RM_LOG}"; teardown_stub_path

echo "test: stream_dump_to_s3 dump failure deletes partial"
setup_stub_path
S3_BUCKET="b" S3_ENDPOINT="https://e" HOST_DATA_DIR="/host/data" DATA_DIR="/data"
make_stub du 'echo "1	$2"'
make_stub docker 'exit 1'   # dump fails
make_stub aws '
case "$1 $2" in
  "s3 cp") cat >/dev/null; exit 0 ;;
  "s3 rm") echo "$@" >> "${RM_LOG}"; exit 0 ;;
esac'
RM_LOG="$(mktemp "${TMPDIR:-/tmp}/rmlog.XXXXXX")"; export RM_LOG
stream_dump_to_s3 neo4j 2026-06-16; assert_failure $? "dump failure => failure"
if grep -q "neo4j.dump" "${RM_LOG}"; then assert_success 0 "partial deleted on dump failure"; else assert_failure 0 "partial deleted on dump failure"; fi
rm -f "${RM_LOG}"; teardown_stub_path

echo "test: stream_dump_to_s3 upload failure deletes partial"
setup_stub_path
S3_BUCKET="b" S3_ENDPOINT="https://e" HOST_DATA_DIR="/host/data" DATA_DIR="/data"
make_stub du 'echo "1	$2"'
make_stub docker 'if [ "$1" = run ]; then printf "DUMPDATA"; fi'
make_stub aws '
case "$1 $2" in
  "s3 cp") cat >/dev/null; exit 1 ;;
  "s3 ls") echo "2026-06-16 02:00:01      8 neo4j.dump"; exit 0 ;;
  "s3 rm") echo "$@" >> "${RM_LOG}"; exit 0 ;;
esac'
RM_LOG="$(mktemp "${TMPDIR:-/tmp}/rmlog.XXXXXX")"; export RM_LOG
stream_dump_to_s3 neo4j 2026-06-16; assert_failure $? "upload failure => failure"
if grep -q "neo4j.dump" "${RM_LOG}"; then assert_success 0 "partial deleted on upload failure"; else assert_failure 0 "partial deleted on upload failure"; fi
rm -f "${RM_LOG}"; teardown_stub_path

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

finish
