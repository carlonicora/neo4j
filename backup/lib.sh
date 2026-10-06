#!/bin/bash
# Shared library for Neo4j backup/restore scripts.
# Sourced by backup.sh, retention.sh, restore.sh. Functions that use pipelines save and restore `pipefail` around their pipelines.
# NEO4J_ADMIN_IMAGE and DATA_DIR are used by restore (load); backups themselves come from the hot backup plugin.

NEO4J_ADMIN_IMAGE="${NEO4J_ADMIN_IMAGE:-neo4j/neo4j-admin:5.26-community-bullseye}"
DATA_DIR="${DATA_DIR:-/data}"
BACKUP_ROOT="${BACKUP_ROOT:-/backups}"

# Write the variables the cron jobs need to <file>, one shell-safe assignment per line.
# Values are quoted with printf %q so spaces, quotes, $ and ; in a password survive `source`.
write_backup_env_file() {
  local file="$1" name value
  : > "${file}"
  chmod 600 "${file}"
  env | grep -E '^(AWS_|S3_|HOST_|COMPOSE_|BACKUP_|DOCKER_HOST|NEO4J_AUTH)' | while IFS= read -r line; do
    name="${line%%=*}"
    value="${line#*=}"
    printf '%s=%q\n' "${name}" "${value}" >> "${file}"
  done
}

# ---------------------------------------------------------------------------
# Retention policy (BACKUP_RETENTION), GFS counts in the borg / restic sense:
#   last=N      keep the N newest backups
#   daily=N     keep the newest backup of each of the last N days that have one
#   weekly=N    same per week (Monday to Sunday)
#   monthly=N   same per calendar month
#   yearly=N    same per calendar year
# Rules apply in that order. A backup kept by an earlier rule still occupies its
# period for later rules but does not count towards their N. Periods without a
# backup are skipped. Backups are identified by their YYYY-MM-DD date.
# ---------------------------------------------------------------------------
RETENTION_DEFAULT="daily=7,weekly=4,monthly=12"

# Days since 1970-01-01 for a YYYY-MM-DD date. Pure arithmetic (no `date`, portable).
date_to_days() {
  local y=${1%%-*} rest=${1#*-}
  local m=${rest%%-*} d=${1##*-}
  y=$((10#$y)); m=$((10#$m)); d=$((10#$d))
  if [ "$m" -le 2 ]; then y=$((y - 1)); fi
  local era=$(( y / 400 ))
  local yoe=$(( y - era * 400 ))
  local mp=$(( (m + 9) % 12 ))
  local doy=$(( (153 * mp + 2) / 5 + d - 1 ))
  local doe=$(( yoe * 365 + yoe / 4 - yoe / 100 + doy ))
  echo $(( era * 146097 + doe - 719468 ))
}

# Period key of <date> under <rule>. Weeks are Monday-based indexes since 1969-12-29.
retention_bucket() {
  local rule="$1" date="$2"
  case "${rule}" in
    last|daily) echo "${date}" ;;
    weekly) echo "w$(( ($(date_to_days "${date}") + 3) / 7 ))" ;;
    monthly) echo "${date%-*}" ;;
    yearly) echo "${date%%-*}" ;;
  esac
}

# Validate a policy string. rc 0 if usable; rc 1 with the reason on stderr.
retention_validate() {
  local spec="$1" item key n total=0 seen=" "
  if [ -z "${spec// /}" ]; then echo "policy is empty" >&2; return 1; fi
  local old_ifs="$IFS"; IFS=','
  for item in ${spec}; do
    IFS="$old_ifs"
    item="${item// /}"
    key="${item%%=*}"; n="${item#*=}"
    case "${key}" in last|daily|weekly|monthly|yearly) ;; *) echo "unknown rule '${item}' (use last, daily, weekly, monthly, yearly)" >&2; return 1 ;; esac
    case "${n}" in ''|*[!0-9]*) echo "'${item}' needs a whole number" >&2; return 1 ;; esac
    case "${seen}" in *" ${key} "*) echo "rule '${key}' given twice" >&2; return 1 ;; esac
    seen="${seen}${key} "
    total=$((total + 10#$n))
    IFS=','
  done
  IFS="$old_ifs"
  if [ "${total}" -eq 0 ]; then echo "every count is zero, refusing to delete everything" >&2; return 1; fi
  return 0
}

# Echo the count for <rule> in <spec> (0 when absent). Assumes a validated spec.
retention_count() {
  local spec="$1" rule="$2" item old_ifs="$IFS"
  IFS=','
  for item in ${spec}; do
    item="${item// /}"
    if [ "${item%%=*}" = "${rule}" ]; then IFS="$old_ifs"; echo $((10#${item#*=})); return 0; fi
  done
  IFS="$old_ifs"
  echo 0
}

# From the YYYY-MM-DD dates given as arguments, echo "<date> <rule>" for every date the
# policy keeps. Anything not echoed is to be deleted. rc 1 (and no output) on a bad policy.
retention_keep_dates() {
  local spec="$1"; shift
  retention_validate "${spec}" || return 1
  local dates
  dates=$(printf '%s\n' "$@" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' | sort -r -u)
  local kept=" " rule n d bucket last count
  for rule in last daily weekly monthly yearly; do
    n=$(retention_count "${spec}" "${rule}")
    [ "${n}" -gt 0 ] || continue
    last=""; count=0
    for d in ${dates}; do
      bucket=$(retention_bucket "${rule}" "${d}")
      [ "${bucket}" != "${last}" ] || continue
      last="${bucket}"
      case "${kept}" in *" ${d} "*) continue ;; esac
      kept="${kept}${d} "
      echo "${d} ${rule}"
      count=$((count + 1))
      [ "${count}" -lt "${n}" ] || break
    done
  done
  return 0
}

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
