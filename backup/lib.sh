#!/bin/bash
# Shared library for Neo4j backup/restore scripts.
# Sourced by backup.sh, retention.sh, restore.sh. Functions that use pipelines save and restore `pipefail` around their pipelines.
# NEO4J_ADMIN_IMAGE and DATA_DIR are used by restore (load); backups themselves come from the hot backup plugin.

NEO4J_ADMIN_IMAGE="${NEO4J_ADMIN_IMAGE:-neo4j/neo4j-admin:5.26-community-bullseye}"
DATA_DIR="${DATA_DIR:-/data}"
BACKUP_ROOT="${BACKUP_ROOT:-/backups}"

# True when S3-compatible storage is configured. Connection logic is unchanged.
s3_configured() {
  [ -n "${S3_BUCKET:-}" ] && [ -n "${S3_ENDPOINT:-}" ]
}

# Echo the byte size of an S3 object (empty if it does not exist).
s3_object_size() {
  local key="$1"
  aws s3 ls "s3://${S3_BUCKET}/${key}" --endpoint-url "${S3_ENDPOINT}" 2>/dev/null \
    | awk '{print $3}' | head -1
}

# Upload a finished dump file to S3 as <date>/<db>.dump and verify it landed with the same
# size. rc 0 = uploaded and verified; rc 1 = failure (partial object removed, local file untouched).
upload_dump_to_s3() {
  local file="$1" db="$2" date="$3"
  local key="${date}/${db}.dump"
  local local_size remote_size
  local_size=$(wc -c < "${file}" | tr -d '[:space:]')
  if aws s3 cp "${file}" "s3://${S3_BUCKET}/${key}" --endpoint-url "${S3_ENDPOINT}" --no-progress; then
    remote_size=$(s3_object_size "${key}")
    if [ -n "${remote_size}" ] && [ "${remote_size}" = "${local_size}" ]; then
      return 0
    fi
  fi
  aws s3 rm "s3://${S3_BUCKET}/${key}" --endpoint-url "${S3_ENDPOINT}" --quiet 2>/dev/null || true
  return 1
}

# In S3 mode, push any pre-existing local date dirs to S3, verify, then delete them.
# Unverified dirs are kept and retried on the next run. Clears the local-disk backlog.
drain_local_backlog() {
  local dir date local_count remote_count
  for dir in "${BACKUP_ROOT}"/????-??-??; do
    [ -d "${dir}" ] || continue
    date=$(basename "${dir}")
    local_count=$(find "${dir}" -type f ! -name '.*' 2>/dev/null | wc -l | tr -d '[:space:]')
    if [ -z "${local_count}" ] || [ "${local_count}" -eq 0 ]; then
      rmdir "${dir}" 2>/dev/null || true
      continue
    fi
    if aws s3 cp "${dir}/" "s3://${S3_BUCKET}/${date}/" \
         --recursive --endpoint-url "${S3_ENDPOINT}" --no-progress 2>/dev/null; then
      remote_count=$(aws s3 ls "s3://${S3_BUCKET}/${date}/" \
         --recursive --endpoint-url "${S3_ENDPOINT}" 2>/dev/null | grep -c .) || remote_count=0
      if [ "${remote_count:-0}" -ge "${local_count}" ]; then
        rm -rf "${dir}"
      fi
    fi
  done
}

# Echo database names (one per line) found under an S3 date prefix.
list_s3_databases() {
  local date="$1"
  aws s3 ls "s3://${S3_BUCKET}/${date}/" --endpoint-url "${S3_ENDPOINT}" 2>/dev/null \
    | awk '{print $4}' | grep '\.dump$' | sed 's/\.dump$//'
}

# Stream a dump from S3 directly into `neo4j-admin database load --from-stdin`.
# rc 0 on success, rc 1 on failure.
stream_load_from_s3() {
  local db="$1" date="$2"
  local _pipefail_was
  _pipefail_was=$(set +o | grep pipefail)
  set -o pipefail
  aws s3 cp "s3://${S3_BUCKET}/${date}/${db}.dump" - \
      --endpoint-url "${S3_ENDPOINT}" --no-progress \
    | docker run --rm -i -v "${HOST_DATA_DIR}:/data" "${NEO4J_ADMIN_IMAGE}" \
        neo4j-admin database load "${db}" --from-stdin --overwrite-destination=true
  local rc=$?
  eval "${_pipefail_was}"
  return ${rc}
}
