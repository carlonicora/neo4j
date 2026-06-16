#!/bin/bash
# Shared library for Neo4j backup/restore scripts.
# Sourced by backup.sh, retention.sh, restore.sh. Functions that use pipelines save and restore `pipefail` around their pipelines.

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
  [ -n "${1:-}" ] || { echo 0; return 1; }
  local db="$1" kb
  kb=$(du -sk "${DATA_DIR}/databases/${db}" 2>/dev/null | cut -f1)
  if [ -z "${kb}" ]; then echo 0; return 1; fi
  echo $(( kb * 1024 ))
}

# Echo the byte size of an S3 object (empty if it does not exist).
s3_object_size() {
  local key="$1"
  aws s3 ls "s3://${S3_BUCKET}/${key}" --endpoint-url "${S3_ENDPOINT}" 2>/dev/null \
    | awk '{print $3}' | head -1
}

# Stream a dump of <db> straight to S3 and verify byte count. Never stages on disk.
# rc 0 = streamed and verified; rc 1 = failure (partial object removed).
stream_dump_to_s3() {
  local db="$1" date="$2"
  local key="${date}/${db}.dump"
  local est size_file streamed remote rc
  local _pipefail_was
  _pipefail_was=$(set +o | grep pipefail)
  set -o pipefail

  est=$(estimate_dump_size "$db")
  size_file=$(mktemp "${TMPDIR:-/tmp}/dumpsize.XXXXXX")

  # Build aws args; only pass --expected-size when we have a positive estimate.
  local -a cp_args
  cp_args=(s3 cp - "s3://${S3_BUCKET}/${key}" --endpoint-url "${S3_ENDPOINT}" --no-progress)
  if [ "${est}" -gt 0 ] 2>/dev/null; then
    cp_args+=(--expected-size "${est}")
  fi

  docker run --rm -v "${HOST_DATA_DIR}:/data" "${NEO4J_ADMIN_IMAGE}" \
      neo4j-admin database dump "${db}" --to-stdout 2>/dev/null \
    | tee >(wc -c > "${size_file}") \
    | aws "${cp_args[@]}"
  rc=$?

  streamed=$(tr -d '[:space:]' < "${size_file}" 2>/dev/null)
  rm -f "${size_file}"

  if [ "${rc}" -eq 0 ]; then
    remote=$(s3_object_size "${key}")
    if [ -n "${streamed}" ] && [ "${streamed}" = "${remote}" ] && [ "${streamed}" -gt 0 ] 2>/dev/null; then
      eval "${_pipefail_was}"
      return 0
    fi
  fi

  # Failure or verification mismatch: remove the partial object, keep prior backups intact.
  aws s3 rm "s3://${S3_BUCKET}/${key}" --endpoint-url "${S3_ENDPOINT}" --quiet 2>/dev/null || true
  eval "${_pipefail_was}"
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
