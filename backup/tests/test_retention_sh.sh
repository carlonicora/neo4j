#!/bin/bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/helpers.sh"

echo "syntax: retention.sh"
bash -n "${HERE}/../retention.sh"; assert_success $? "retention.sh parses"

echo "smoke: retention drains backlog in S3 mode"
setup_stub_path
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ret.XXXXXX")"
mkdir -p "${WORK}/2026-03-10"; printf x > "${WORK}/2026-03-10/neo4j.dump"
make_stub aws '
case "$1 $2" in
  "s3 cp") exit 0 ;;
  "s3 ls") echo "2026-03-10 00:00:00      1 neo4j.dump"; exit 0 ;;
esac'
BACKUP_ROOT="${WORK}" S3_BUCKET="b" S3_ENDPOINT="https://e" \
  bash "${HERE}/../retention.sh" >/dev/null 2>&1
assert_success $? "retention S3-mode run succeeds"
if [ -d "${WORK}/2026-03-10" ]; then assert_failure 0 "backlog dir drained"; else assert_success 0 "backlog dir drained"; fi
rm -rf "${WORK}"; teardown_stub_path

echo "test: local mode applies BACKUP_RETENTION to date folders"
setup_stub_path
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ret.XXXXXX")"
for d in 2026-10-06 2026-10-05 2026-10-04; do mkdir -p "${WORK}/${d}"; printf x > "${WORK}/${d}/neo4j.dump"; done
BACKUP_ROOT="${WORK}" S3_BUCKET="" S3_ENDPOINT="" BACKUP_RETENTION="daily=2" \
  bash "${HERE}/../retention.sh" > "${WORK}/out.log" 2>&1
assert_success $? "local run succeeds"
if [ -d "${WORK}/2026-10-06" ] && [ -d "${WORK}/2026-10-05" ]; then assert_success 0 "two newest kept"; else assert_failure 0 "two newest kept"; fi
if [ -d "${WORK}/2026-10-04" ]; then assert_failure 0 "oldest removed"; else assert_success 0 "oldest removed"; fi
if grep -q "Keeping local: 2026-10-06 (daily)" "${WORK}/out.log"; then assert_success 0 "log names the rule"; else assert_failure 0 "log names the rule"; fi
rm -rf "${WORK}"; teardown_stub_path

echo "test: invalid BACKUP_RETENTION deletes nothing and fails"
setup_stub_path
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ret.XXXXXX")"
for d in 2026-10-06 2026-01-01; do mkdir -p "${WORK}/${d}"; done
BACKUP_ROOT="${WORK}" S3_BUCKET="" S3_ENDPOINT="" BACKUP_RETENTION="daily=0" \
  bash "${HERE}/../retention.sh" > "${WORK}/out.log" 2>&1
assert_failure $? "invalid policy => non-zero exit"
if [ -d "${WORK}/2026-01-01" ]; then assert_success 0 "nothing deleted"; else assert_failure 0 "nothing deleted"; fi
if grep -q "Nothing deleted" "${WORK}/out.log"; then assert_success 0 "error explains itself"; else assert_failure 0 "error explains itself"; fi
rm -rf "${WORK}"; teardown_stub_path

echo "test: unset BACKUP_RETENTION uses the default daily=7,weekly=4,monthly=12"
setup_stub_path
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ret.XXXXXX")"
mkdir -p "${WORK}/2026-10-06"
( unset BACKUP_RETENTION; BACKUP_ROOT="${WORK}" S3_BUCKET="" S3_ENDPOINT="" bash "${HERE}/../retention.sh" ) > "${WORK}/out.log" 2>&1
assert_success $? "default run succeeds"
if grep -q "Policy: daily=7,weekly=4,monthly=12" "${WORK}/out.log"; then assert_success 0 "default policy logged"; else assert_failure 0 "default policy logged"; fi
rm -rf "${WORK}"; teardown_stub_path

echo "test: S3 mode applies BACKUP_RETENTION to date prefixes"
setup_stub_path
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ret.XXXXXX")"
make_stub aws '
case "$1 $2" in
  "s3 ls") printf "                           PRE 2026-10-06/\n                           PRE 2026-10-05/\n                           PRE 2026-10-04/\n"; exit 0 ;;
  "s3 rm") echo "$3" >> "${RM_LOG}"; exit 0 ;;
esac'
RM_LOG="$(mktemp "${TMPDIR:-/tmp}/rmlog.XXXXXX")"; export RM_LOG
BACKUP_ROOT="${WORK}" S3_BUCKET="b" S3_ENDPOINT="https://e" BACKUP_RETENTION="daily=2" \
  bash "${HERE}/../retention.sh" >/dev/null 2>&1
assert_success $? "S3 run succeeds"
assert_eq "s3://b/2026-10-04/" "$(cat "${RM_LOG}")" "only the oldest prefix removed"
rm -rf "${WORK}"; rm -f "${RM_LOG}"; teardown_stub_path

# Regression guard: `aws s3 rm` rejects --no-progress (only cp/mv/sync accept it).
# Any `aws s3 rm` must use --quiet, or S3-side cleanup silently fails. This caught a
# real bug in retention.sh's S3 retention pruning.
echo "static: no 'aws s3 rm' uses --no-progress"
BAD=$(grep -rn -A3 'aws s3 rm' "${HERE}/../lib.sh" "${HERE}/../retention.sh" "${HERE}/../backup.sh" "${HERE}/../restore.sh" 2>/dev/null | grep -c -- '--no-progress')
assert_eq "0" "${BAD}" "no 'aws s3 rm ... --no-progress' anywhere"

finish
