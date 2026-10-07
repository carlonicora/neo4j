#!/bin/bash
# Shared library for Neo4j backup/restore scripts.
# Sourced by backup.sh, retention.sh, restore.sh. Functions that use pipelines save and restore `pipefail` around their pipelines.
# NEO4J_ADMIN_IMAGE is used by restore (load); backups themselves come from the hot backup plugin.
# DATA_DIR is the Neo4j data dir, mounted read-only (used to estimate dump sizes).

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
# Backup schedule (BACKUP_SCHEDULE): a standard 5-field cron expression, server timezone.
# ---------------------------------------------------------------------------
SCHEDULE_DEFAULT="0 2 * * *"

# resolve_backup_schedule <value>: echo the cron expression to install.
# Empty => the default, rc 0. Valid (exactly 5 whitespace-separated fields, each made only of
# digits, *, /, , and -) => the value with whitespace normalised, rc 0. Anything else => the
# default, rc 1, with the reason on stderr (the backups must still run).
resolve_backup_schedule() {
  local spec="$1" f1 f2 f3 f4 f5 extra
  if [ -z "${spec//[[:space:]]/}" ]; then echo "${SCHEDULE_DEFAULT}"; return 0; fi
  # Whole-string character check first: also rejects newlines, ; and anything a crontab line could misread.
  case "${spec}" in
    *[!0-9*/,[:blank:]-]*) echo "contains characters other than digits, *, /, , and -" >&2; echo "${SCHEDULE_DEFAULT}"; return 1 ;;
  esac
  read -r f1 f2 f3 f4 f5 extra <<< "${spec}"
  if [ -z "${f5}" ] || [ -n "${extra}" ]; then
    echo "needs exactly 5 fields (minute hour day-of-month month day-of-week)" >&2
    echo "${SCHEDULE_DEFAULT}"; return 1
  fi
  echo "${f1} ${f2} ${f3} ${f4} ${f5}"
}

# ---------------------------------------------------------------------------
# Retention policy (BACKUP_RETENTION). Rules are calendar windows counted back from
# today, today included, applied to COMPLETE backup dates only:
#   last=N      the N newest complete dates
#   daily=N     every complete date within the last N calendar days
#   weekly=N    the newest complete date in each of the last N calendar weeks (Monday to Sunday)
#   monthly=N   the newest complete date in each of the last N calendar months
#   yearly=N    the newest complete date in each of the last N calendar years
# A date kept by any rule survives; everything else is deleted. A date is complete when it
# holds <db>.dump for every database in the current database list; incomplete dates never
# count and are always deleted. Backups are identified by their YYYY-MM-DD date.
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

# Calendar period index of <date> under <rule>: consecutive periods have consecutive
# indexes, so "today's index minus this index" is how many periods ago it is.
# Weeks are Monday-based (1969-12-29 was a Monday).
retention_period() {
  local rule="$1" date="$2" y m
  y=$((10#${date%%-*}))
  m=${date#*-}; m=$((10#${m%%-*}))
  case "${rule}" in
    daily) date_to_days "${date}" ;;
    weekly) echo $(( ($(date_to_days "${date}") + 3) / 7 )) ;;
    monthly) echo $(( y * 12 + m - 1 )) ;;
    yearly) echo "${y}" ;;
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

# retention_keep_dates <spec> <today> <complete dates...>
# Echo "<date> <rule>" for every complete date the policy keeps (first rule that keeps it).
# Anything not echoed is to be deleted. Pass only COMPLETE dates. rc 1 (no output) on a bad policy.
retention_keep_dates() {
  local spec="$1" today="$2"; shift 2
  retention_validate "${spec}" || return 1
  local dates
  dates=$(printf '%s\n' "$@" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' | sort -r -u)
  local kept=" " rule n d period now last count
  for rule in last daily weekly monthly yearly; do
    n=$(retention_count "${spec}" "${rule}")
    [ "${n}" -gt 0 ] || continue
    last=""; count=0
    [ "${rule}" = last ] || now=$(retention_period "${rule}" "${today}")
    for d in ${dates}; do
      if [ "${rule}" = last ]; then
        [ "${count}" -lt "${n}" ] || break
        count=$((count + 1))
      else
        period=$(retention_period "${rule}" "${d}")
        # Dates are newest first: once a period falls outside the window, so do the rest.
        # A date after today (clock skew) counts as inside the window.
        [ $(( now - period )) -lt "${n}" ] || break
        [ "${period}" != "${last}" ] || continue   # only the newest date of each period
        last="${period}"
      fi
      case "${kept}" in *" ${d} "*) continue ;; esac
      kept="${kept}${d} "
      echo "${d} ${rule}"
    done
  done
  return 0
}

# prune_upload_debug_logs <logs dir> <today> <days>: delete the YYYY-MM-DD folders under
# <logs dir> more than <days> days older than <today>, echoing each deleted name. Anything
# else in <logs dir> is left alone. Always rc 0.
prune_upload_debug_logs() {
  local dir="$1" today="$2" keep="$3" path name now
  [ -d "${dir}" ] || return 0
  now=$(date_to_days "${today}")
  for path in "${dir}"/????-??-??; do
    [ -d "${path}" ] || continue
    name="${path##*/}"
    printf '%s\n' "${name}" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || continue
    if [ $(( now - $(date_to_days "${name}") )) -gt "${keep}" ]; then
      rm -rf "${path:?}" 2>/dev/null && echo "${name}"
    fi
  done
  return 0
}

# True when BACKUP_AWS_DEBUG asks for the upload debug log ("1" or "true").
aws_debug_enabled() {
  case "${BACKUP_AWS_DEBUG:-}" in 1|true|TRUE|True) return 0 ;; *) return 1 ;; esac
}

# missing_databases "<dump names present>" "<databases>": echo (space separated) every
# database without a <db>.dump in the first list. Empty output = the date is complete.
missing_databases() {
  local present=" $1 " db missing=""
  for db in $2; do
    case "${present}" in *" ${db}.dump "*) ;; *) missing="${missing}${missing:+ }${db}" ;; esac
  done
  echo "${missing}"
}

# ---------------------------------------------------------------------------
# Talking to Neo4j (cypher-shell inside the Neo4j container)
# ---------------------------------------------------------------------------

# Echo the Neo4j container name: BACKUP_NEO4J_CONTAINER, else a running container whose
# name starts with the service name and is not the backup container, else the Compose default.
resolve_neo4j_container() {
  local service="${NEO4J_SERVICE:-neo4j}" name
  if [ -n "${BACKUP_NEO4J_CONTAINER:-}" ]; then echo "${BACKUP_NEO4J_CONTAINER}"; return 0; fi
  name=$(docker ps --format '{{.Names}}' 2>/dev/null | grep "^${service}" | grep -v backup | head -1) || true
  echo "${name:-${COMPOSE_PROJECT:-neo4j}-${service}-1}"
}

# cypher_rows <container> <database> <query>: run a query that returns one string column
# and echo its values, one per line, header and quotes stripped. rc 1 if cypher-shell fails
# (its output then goes to stderr).
# With CYPHER_TIMEOUT set (seconds), the call is killed after that long (busybox/coreutils `timeout`).
cypher_rows() {
  local container="$1" database="$2" query="$3" out rc=0
  if [ -n "${CYPHER_TIMEOUT:-}" ]; then
    out=$(timeout "${CYPHER_TIMEOUT}" docker exec "${container}" cypher-shell -u "${NEO4J_AUTH%%/*}" -p "${NEO4J_AUTH#*/}" \
          -d "${database}" --format plain "${query}" 2>&1) || rc=$?
  else
    out=$(docker exec "${container}" cypher-shell -u "${NEO4J_AUTH%%/*}" -p "${NEO4J_AUTH#*/}" \
          -d "${database}" --format plain "${query}" 2>&1) || rc=$?
  fi
  if [ "${rc}" -ne 0 ]; then
    [ "${rc}" -ne 124 ] && [ "${rc}" -ne 143 ] || out="timed out after ${CYPHER_TIMEOUT}s. ${out}"
    echo "${out}" >&2
    return 1
  fi
  printf '%s\n' "${out}" | tail -n +2 | sed -e 's/^"//' -e 's/"$//' | grep -v '^$' || true
}

# database_status_rows <container>: echo "<name>|<currentStatus>" for every database.
database_status_rows() {
  local rows
  rows=$(cypher_rows "$1" system \
    "SHOW DATABASES YIELD name, currentStatus RETURN name + '|' + currentStatus AS row") || return 1
  printf '%s\n' "${rows}" | awk -F'|' 'NF >= 2 && !seen[$1]++'
}

# load_database_list: fill DB_ROWS ("<name>|<status>" lines) from NEO4J_CONTAINER, falling
# back to the Compose v1 container name (and updating NEO4J_CONTAINER) if that fails.
# rc 1 with the reason in DB_LIST_ERROR when the list cannot be obtained or is empty.
load_database_list() {
  local err alt out
  DB_ROWS=""; DB_LIST_ERROR=""
  err=$(mktemp "${TMPDIR:-/tmp}/dblist.XXXXXX")
  if out=$(database_status_rows "${NEO4J_CONTAINER}" 2>"${err}") && [ -n "${out}" ]; then
    DB_ROWS="${out}"; rm -f "${err}"; return 0
  fi
  alt="${COMPOSE_PROJECT:-neo4j}_${NEO4J_SERVICE:-neo4j}_1"
  if out=$(database_status_rows "${alt}" 2>/dev/null) && [ -n "${out}" ]; then
    NEO4J_CONTAINER="${alt}"; DB_ROWS="${out}"; rm -f "${err}"; return 0
  fi
  DB_LIST_ERROR=$(cat "${err}")
  [ -n "${DB_LIST_ERROR}" ] || DB_LIST_ERROR="SHOW DATABASES returned no databases"
  rm -f "${err}"
  return 1
}

# Estimate the dump size of <db> in bytes from its store under the read-only /data mount
# (databases/<db> + transactions/<db>). Used as `aws s3 cp --expected-size`, without which
# a stdin upload is capped far below a large dump. Over-estimating is safe. Uses `du -sk`
# (portable across busybox and BSD/macOS). Echoes 0 + rc 1 when the store is not visible.
estimate_dump_size() {
  [ -n "${1:-}" ] || { echo 0; return 1; }
  local db="$1" kb tx
  kb=$(du -sk "${DATA_DIR}/databases/${db}" 2>/dev/null | cut -f1)
  if [ -z "${kb}" ]; then echo 0; return 1; fi
  tx=$(du -sk "${DATA_DIR}/transactions/${db}" 2>/dev/null | cut -f1)
  echo $(( (kb + ${tx:-0}) * 1024 ))
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

# Remove <key> from S3 and abort any multipart upload left open for it, so a failed
# stream leaves nothing behind (no half object, no billed orphan parts).
discard_s3_object() {
  local key="$1" ids id
  aws s3 rm "s3://${S3_BUCKET}/${key}" --endpoint-url "${S3_ENDPOINT}" --quiet >/dev/null 2>&1 || true
  ids=$(aws s3api list-multipart-uploads --bucket "${S3_BUCKET}" --prefix "${key}" \
          --endpoint-url "${S3_ENDPOINT}" --query "Uploads[?Key=='${key}'].UploadId" --output text 2>/dev/null) || ids=""
  for id in ${ids}; do
    [ "${id}" != "None" ] || continue
    aws s3api abort-multipart-upload --bucket "${S3_BUCKET}" --key "${key}" --upload-id "${id}" \
      --endpoint-url "${S3_ENDPOINT}" >/dev/null 2>&1 || true
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
