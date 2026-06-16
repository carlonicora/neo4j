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

# Regression guard: `aws s3 rm` rejects --no-progress (only cp/mv/sync accept it).
# Any `aws s3 rm` must use --quiet, or S3-side cleanup silently fails. This caught a
# real bug in retention.sh's S3 retention pruning.
echo "static: no 'aws s3 rm' uses --no-progress"
BAD=$(grep -rn -A3 'aws s3 rm' "${HERE}/../lib.sh" "${HERE}/../retention.sh" "${HERE}/../backup.sh" "${HERE}/../restore.sh" 2>/dev/null | grep -c -- '--no-progress')
assert_eq "0" "${BAD}" "no 'aws s3 rm ... --no-progress' anywhere"

finish
