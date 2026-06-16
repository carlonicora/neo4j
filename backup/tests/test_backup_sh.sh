#!/bin/bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/helpers.sh"

echo "syntax: backup.sh"
bash -n "${HERE}/../backup.sh"; assert_success $? "backup.sh parses"

echo "smoke: backup.sh streams in S3 mode (no local dir created)"
setup_stub_path
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bk.XXXXXX")"
mkdir -p "${WORK}/data/databases/neo4j"
make_stub docker '
case "$1" in
  run) shift; if printf "%s\n" "$@" | grep -q -- "--to-stdout"; then printf "DUMPDATA"; fi; exit 0 ;;
  update|stop|start|inspect) exit 0 ;;
  ps) echo "neo4j-neo4j-1" ;;
esac'
make_stub aws '
case "$1 $2" in
  "s3 cp") cat >/dev/null 2>&1; exit 0 ;;
  "s3 ls") echo "2026-06-16 02:00:01      8 neo4j.dump"; exit 0 ;;
  "s3 rm") exit 0 ;;
esac'
make_stub du 'echo "1	$2"'
RETENTION_SCRIPT="$(mktemp "${TMPDIR:-/tmp}/ret.XXXXXX")"; printf '#!/bin/bash\nexit 0\n' > "${RETENTION_SCRIPT}"; chmod +x "${RETENTION_SCRIPT}"
export RETENTION_SCRIPT
HOST_DATA_DIR="${WORK}/data" DATA_DIR="${WORK}/data" \
  HOST_BACKUP_DIR="${WORK}/backups" BACKUP_ROOT="${WORK}/backups" \
  S3_BUCKET="b" S3_ENDPOINT="https://e" \
  bash "${HERE}/../backup.sh" >/dev/null 2>&1
assert_success $? "backup.sh S3-mode run succeeds"
if [ -d "${WORK}/backups" ]; then assert_failure 0 "no local backup dir created in S3 mode"; else assert_success 0 "no local backup dir created in S3 mode"; fi
rm -rf "${WORK}" "${RETENTION_SCRIPT}"; teardown_stub_path

finish
