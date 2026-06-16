#!/bin/bash
# Shared library for Neo4j backup/restore scripts.
# Sourced by backup.sh, retention.sh, restore.sh. Assumes `set -o pipefail` in caller;
# functions that pipe also set it locally for safety.

NEO4J_ADMIN_IMAGE="${NEO4J_ADMIN_IMAGE:-neo4j/neo4j-admin:5.26-community-bullseye}"
DATA_DIR="${DATA_DIR:-/data}"
BACKUP_ROOT="${BACKUP_ROOT:-/backups}"

# True when S3-compatible storage is configured. Connection logic is unchanged.
s3_configured() {
  [ -n "${S3_BUCKET:-}" ] && [ -n "${S3_ENDPOINT:-}" ]
}

# Estimate dump size in bytes from the on-disk database footprint.
# Over-estimate is safe: it only enlarges multipart part size. Uses `du -sk`
# (portable across busybox and BSD/macOS). Echoes 0 + rc 1 on failure.
estimate_dump_size() {
  local db="$1" kb
  kb=$(du -sk "${DATA_DIR}/databases/${db}" 2>/dev/null | cut -f1)
  if [ -z "${kb}" ]; then echo 0; return 1; fi
  echo $(( kb * 1024 ))
}
