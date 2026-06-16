# Neo4j S3 Streaming Backups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stream Neo4j database dumps straight to S3-compatible storage so backups never stage on local disk, with byte-level integrity verification and automatic cleanup of the existing local backlog.

**Architecture:** Extract the streaming + verification logic into a sourceable shell library (`backup/lib.sh`) that is unit-tested with stubbed `aws`/`docker`/`du` binaries. Wire the library into `backup.sh` (stream-to-S3 dump path), `retention.sh` (S3-mode local drain), and `restore.sh` (stream-from-S3 load path). When `S3_BUCKET` + `S3_ENDPOINT` are set the scripts run in "S3 mode"; otherwise the existing local-disk behaviour is preserved unchanged.

**Tech Stack:** Bash (target: busybox/Alpine in the `docker:27-cli` backup image; tests must also run on macOS bash 3.2), AWS CLI (`aws s3 ... --endpoint-url`), `neo4j-admin 5.26` (`database dump --to-stdout` / `database load --from-stdin`), Docker CLI.

**Non-goals (hard constraints from the spec):** Do NOT change which S3 is used or how we connect to it — same `S3_BUCKET`/`S3_ENDPOINT`/`AWS_*` vars and the same `aws s3 ... --endpoint-url "${S3_ENDPOINT}"` mechanism. Do NOT use neo4j-admin native `--to-path=s3://`. No new config variables.

---

## File Structure

- **Create** `backup/lib.sh` — sourceable library. Responsibilities: detect S3 mode, resolve the neo4j-admin image, estimate dump size, stream a dump to S3 with verification, drain the local backlog, list S3 databases, stream a load from S3. This is the unit-tested core.
- **Create** `backup/tests/helpers.sh` — test harness (assertions, stub-PATH setup). No external test framework.
- **Create** `backup/tests/test_lib.sh` — runnable test suite for `lib.sh` using stubs.
- **Modify** `backup/backup.sh` — source `lib.sh`; branch the dump phase to stream in S3 mode; drop the now-redundant post-dump upload phase; relax the `HOST_BACKUP_DIR` pre-flight to S3 mode only; make the retention-script path injectable for tests.
- **Modify** `backup/retention.sh` — source `lib.sh`; in S3 mode drain the local backlog instead of applying the local 7/28/365 policy; S3 retention unchanged.
- **Modify** `backup/restore.sh` — source `lib.sh`; in S3 mode stream each database from S3 via `--from-stdin` instead of downloading to disk; local path preserved.
- **Modify** `backup/Dockerfile` — `COPY lib.sh` and the `tests/` dir; keep `chmod +x`.
- **Modify** `README.md` — document the zero-local-disk streaming behaviour.

**Library contract (names used across all tasks — keep identical):**

| Function | Signature | Returns |
|----------|-----------|---------|
| `s3_configured` | `s3_configured` | rc 0 if both `S3_BUCKET` and `S3_ENDPOINT` non-empty |
| `estimate_dump_size` | `estimate_dump_size <db>` | echoes estimated bytes (kb×1024); rc 1 + echoes `0` on failure |
| `s3_object_size` | `s3_object_size <key>` | echoes size in bytes of `s3://$S3_BUCKET/<key>` (empty if absent) |
| `stream_dump_to_s3` | `stream_dump_to_s3 <db> <date>` | rc 0 if streamed+verified; rc 1 otherwise (removes partial object) |
| `drain_local_backlog` | `drain_local_backlog` | uploads+verifies+deletes local date dirs; keeps unverified |
| `list_s3_databases` | `list_s3_databases <date>` | echoes db names (one per line) found under the date prefix |
| `stream_load_from_s3` | `stream_load_from_s3 <db> <date>` | rc 0 if loaded; rc 1 otherwise |

Shared variables (defined in `lib.sh`, overridable by env): `NEO4J_ADMIN_IMAGE` (default `neo4j/neo4j-admin:5.26-community-bullseye`), `DATA_DIR` (default `/data`), `BACKUP_ROOT` (default `/backups`).

---

## Task 1: Library scaffold + S3 detection + image var + size estimation

**Files:**
- Create: `backup/lib.sh`
- Create: `backup/tests/helpers.sh`
- Create: `backup/tests/test_lib.sh`

- [ ] **Step 1: Write the test harness**

Create `backup/tests/helpers.sh`:

```bash
#!/bin/bash
# Test helpers for backup/lib.sh. Bash 3.2 compatible (no associative arrays/mapfile).
set -uo pipefail

TESTS_RUN=0
TESTS_FAILED=0

setup_stub_path() {
  STUB_BIN=$(mktemp -d "${TMPDIR:-/tmp}/stubbin.XXXXXX")
  ORIG_PATH="$PATH"
  PATH="${STUB_BIN}:${PATH}"
  export PATH
}

teardown_stub_path() {
  PATH="${ORIG_PATH}"
  rm -rf "${STUB_BIN}"
}

# make_stub <name> <body-of-script>
make_stub() {
  local name="$1" body="$2"
  printf '#!/bin/bash\n%s\n' "${body}" > "${STUB_BIN}/${name}"
  chmod +x "${STUB_BIN}/${name}"
}

assert_eq() {
  TESTS_RUN=$((TESTS_RUN+1))
  if [ "$1" = "$2" ]; then echo "  ok: $3";
  else TESTS_FAILED=$((TESTS_FAILED+1)); echo "  FAIL: $3 (expected '$1', got '$2')"; fi
}
assert_success() {
  TESTS_RUN=$((TESTS_RUN+1))
  if [ "$1" -eq 0 ]; then echo "  ok: $2"; else TESTS_FAILED=$((TESTS_FAILED+1)); echo "  FAIL: $2 (rc=$1)"; fi
}
assert_failure() {
  TESTS_RUN=$((TESTS_RUN+1))
  if [ "$1" -ne 0 ]; then echo "  ok: $2"; else TESTS_FAILED=$((TESTS_FAILED+1)); echo "  FAIL: $2 (expected failure, got rc 0)"; fi
}
finish() {
  echo "----"; echo "Ran ${TESTS_RUN}, failed ${TESTS_FAILED}"
  [ "${TESTS_FAILED}" -eq 0 ]
}
```

- [ ] **Step 2: Write the failing tests for Task 1 functions**

Create `backup/tests/test_lib.sh`:

```bash
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

echo "test: NEO4J_ADMIN_IMAGE default"
assert_eq "neo4j/neo4j-admin:5.26-community-bullseye" "${NEO4J_ADMIN_IMAGE}" "image default set"

echo "test: estimate_dump_size"
setup_stub_path
make_stub du 'echo "100	$2"'   # du -sk <path> => 100 KB
DATA_DIR="/data"
assert_eq "102400" "$(estimate_dump_size neo4j)" "100KB => 102400 bytes"
teardown_stub_path

finish
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bash backup/tests/test_lib.sh`
Expected: FAIL — `lib.sh` does not exist yet (`source: lib.sh: No such file or directory`).

- [ ] **Step 4: Create `backup/lib.sh` with the Task 1 functions**

```bash
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
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash backup/tests/test_lib.sh`
Expected: PASS — all `ok:` lines, `Ran N, failed 0`.

- [ ] **Step 6: Commit**

```bash
git add backup/lib.sh backup/tests/helpers.sh backup/tests/test_lib.sh
git commit -m "feat(backup): add lib scaffold with S3 detection and dump-size estimation"
```

---

## Task 2: Stream dump to S3 with byte-count verification

**Files:**
- Modify: `backup/lib.sh`
- Modify: `backup/tests/test_lib.sh`

- [ ] **Step 1: Add failing tests for `s3_object_size` and `stream_dump_to_s3`**

Append to `backup/tests/test_lib.sh` *before* the final `finish` call:

```bash
echo "test: s3_object_size"
setup_stub_path
S3_BUCKET="b" S3_ENDPOINT="https://e"
make_stub aws 'if [ "$1 $2" = "s3 ls" ]; then echo "2026-06-16 02:00:01      8 neo4j.dump"; fi'
assert_eq "8" "$(s3_object_size 2026-06-16/neo4j.dump)" "parses size column"
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
  "s3 ls") echo "2026-06-16 02:00:01      4 neo4j.dump"; exit 0 ;;   # wrong size
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
  "s3 ls") echo "2026-06-16 02:00:01      0 neo4j.dump"; exit 0 ;;
  "s3 rm") echo "$@" >> "${RM_LOG}"; exit 0 ;;
esac'
RM_LOG="$(mktemp "${TMPDIR:-/tmp}/rmlog.XXXXXX")"; export RM_LOG
stream_dump_to_s3 neo4j 2026-06-16; assert_failure $? "dump failure => failure"
if grep -q "neo4j.dump" "${RM_LOG}"; then assert_success 0 "partial deleted on dump failure"; else assert_failure 0 "partial deleted on dump failure"; fi
rm -f "${RM_LOG}"; teardown_stub_path
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash backup/tests/test_lib.sh`
Expected: FAIL — `s3_object_size`/`stream_dump_to_s3` not defined (command not found / rc nonzero).

- [ ] **Step 3: Implement the functions in `backup/lib.sh`**

Append to `backup/lib.sh`:

```bash
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
      return 0
    fi
  fi

  # Failure or verification mismatch: remove the partial object, keep prior backups intact.
  aws s3 rm "s3://${S3_BUCKET}/${key}" --endpoint-url "${S3_ENDPOINT}" --no-progress 2>/dev/null || true
  return 1
}
```

> Note: `tee >(wc -c …)` is process substitution; its exit status is not part of the
> pipeline, so `pipefail` reflects only the `docker` (dump) and `aws` (upload) stages —
> exactly the two we want to gate on.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash backup/tests/test_lib.sh`
Expected: PASS — `Ran N, failed 0`.

- [ ] **Step 5: Commit**

```bash
git add backup/lib.sh backup/tests/test_lib.sh
git commit -m "feat(backup): stream dump to S3 with byte-count verification"
```

---

## Task 3: Drain the local backlog in S3 mode

**Files:**
- Modify: `backup/lib.sh`
- Modify: `backup/tests/test_lib.sh`

- [ ] **Step 1: Add failing tests for `drain_local_backlog`**

Append to `backup/tests/test_lib.sh` before `finish`:

```bash
echo "test: drain_local_backlog removes verified dir"
setup_stub_path
S3_BUCKET="b" S3_ENDPOINT="https://e"
BACKUP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/backups.XXXXXX")"
mkdir -p "${BACKUP_ROOT}/2026-03-10"; printf x > "${BACKUP_ROOT}/2026-03-10/neo4j.dump"
make_stub aws '
case "$1 $2" in
  "s3 cp") exit 0 ;;
  "s3 ls") echo "2026-03-10 00:00:00      1 neo4j.dump"; exit 0 ;;   # 1 object >= 1 local file
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
  "s3 cp") exit 1 ;;          # upload fails
  "s3 ls") exit 0 ;;          # nothing listed
esac'
drain_local_backlog
if [ -d "${BACKUP_ROOT}/2026-03-11" ]; then assert_success 0 "failed upload keeps dir"; else assert_failure 0 "failed upload keeps dir"; fi
rm -rf "${BACKUP_ROOT}"; teardown_stub_path
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash backup/tests/test_lib.sh`
Expected: FAIL — `drain_local_backlog: command not found`.

- [ ] **Step 3: Implement `drain_local_backlog` in `backup/lib.sh`**

Append to `backup/lib.sh`:

```bash
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
         --recursive --endpoint-url "${S3_ENDPOINT}" 2>/dev/null | grep -c .)
      if [ "${remote_count:-0}" -ge "${local_count}" ]; then
        rm -rf "${dir}"
      fi
    fi
  done
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash backup/tests/test_lib.sh`
Expected: PASS — `Ran N, failed 0`.

- [ ] **Step 5: Commit**

```bash
git add backup/lib.sh backup/tests/test_lib.sh
git commit -m "feat(backup): drain local backlog to S3 in S3 mode"
```

---

## Task 4: List S3 databases and stream-load from S3 (restore support)

**Files:**
- Modify: `backup/lib.sh`
- Modify: `backup/tests/test_lib.sh`

- [ ] **Step 1: Add failing tests for `list_s3_databases` and `stream_load_from_s3`**

Append to `backup/tests/test_lib.sh` before `finish`:

```bash
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
make_stub docker 'if [ "$1" = run ]; then cat >/dev/null; exit 1; fi'   # load fails
stream_load_from_s3 neo4j 2026-06-16; assert_failure $? "load failure => rc 1"
teardown_stub_path
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash backup/tests/test_lib.sh`
Expected: FAIL — `list_s3_databases` / `stream_load_from_s3` not defined.

- [ ] **Step 3: Implement the functions in `backup/lib.sh`**

Append to `backup/lib.sh`:

```bash
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
  set -o pipefail
  aws s3 cp "s3://${S3_BUCKET}/${date}/${db}.dump" - \
      --endpoint-url "${S3_ENDPOINT}" --no-progress \
    | docker run --rm -i -v "${HOST_DATA_DIR}:/data" "${NEO4J_ADMIN_IMAGE}" \
        neo4j-admin database load "${db}" --from-stdin --overwrite-destination=true
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash backup/tests/test_lib.sh`
Expected: PASS — `Ran N, failed 0`.

- [ ] **Step 5: Commit**

```bash
git add backup/lib.sh backup/tests/test_lib.sh
git commit -m "feat(backup): list S3 databases and stream-load from S3"
```

---

## Task 5: Wire streaming into `backup.sh`

**Files:**
- Modify: `backup/backup.sh:25-49` (pre-flight + source lib), `backup/backup.sh:86-128` (dump/upload/retention phases)
- Modify: `backup/Dockerfile`

- [ ] **Step 1: Source the library and relax the `HOST_BACKUP_DIR` pre-flight**

In `backup/backup.sh`, immediately after the `source /etc/environment.backup` block (after line 9), add:

```bash
# Load shared library (resolve dir so manual invocation also works)
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${LIB_DIR}/lib.sh"
```

Then replace the `HOST_BACKUP_DIR` pre-flight check at `backup/backup.sh:42-45`:

```bash
if [ -z "${HOST_BACKUP_DIR}" ]; then
  log "Backup not configured (HOST_BACKUP_DIR not set). Skipping."
  exit 0
fi
```

with (local staging dir only required when S3 is NOT configured):

```bash
if ! s3_configured && [ -z "${HOST_BACKUP_DIR}" ]; then
  log "Backup not configured (HOST_BACKUP_DIR not set and no S3). Skipping."
  exit 0
fi
```

- [ ] **Step 2: Branch the dump phase to stream in S3 mode**

Replace the dump phase `backup/backup.sh:86-101` (the `mkdir -p "${BACKUP_DIR}"` line through the end of the per-database dump `for` loop) with:

```bash
# --- Phase 3: Dump each database ---
if s3_configured; then
  log "S3 configured: streaming dumps directly to s3://${S3_BUCKET}/${TODAY}/ (no local staging)"
  for db in "${DATABASES[@]}"; do
    log "Streaming database to S3: ${db}..."
    if stream_dump_to_s3 "${db}" "${TODAY}"; then
      log "  OK: ${db}"
    else
      log "  FAILED: ${db} (partial S3 object removed; previous backups intact)"
      DUMP_FAILED=1
    fi
  done
else
  mkdir -p "${BACKUP_DIR}"
  for db in "${DATABASES[@]}"; do
    log "Dumping database: ${db}..."
    if docker run --rm \
      -v "${HOST_DATA_DIR}:/data" \
      -v "${HOST_BACKUP_DIR}/${TODAY}:/backups" \
      "${NEO4J_ADMIN_IMAGE}" \
      neo4j-admin database dump "${db}" --to-path=/backups --overwrite-destination=true 2>&1; then
      log "  OK: ${db}"
    else
      log "  FAILED: ${db}"
      DUMP_FAILED=1
    fi
  done
fi
```

- [ ] **Step 3: Remove the now-redundant Phase 5 upload**

Delete the entire Phase 5 block at `backup/backup.sh:111-122` (the `# --- Phase 5: Upload to S3 ---` comment through its closing `fi`). In S3 mode the dump is already in S3; in local mode there is no S3. Leave Phase 4 (restart) and Phase 6 (retention) intact.

- [ ] **Step 4: Make the retention-script path injectable (for the Task 6 smoke test)**

Replace `backup/backup.sh:125` (`/usr/local/bin/retention.sh`) with:

```bash
"${RETENTION_SCRIPT:-${LIB_DIR}/retention.sh}"
```

- [ ] **Step 5: Update the Dockerfile to ship `lib.sh` and tests**

In `backup/Dockerfile`, after the `COPY restore.sh ...` line (line 11) add:

```dockerfile
COPY lib.sh /usr/local/bin/lib.sh
COPY tests/ /usr/local/bin/tests/
```

(`LIB_DIR` resolves to `/usr/local/bin` at runtime, so `source "${LIB_DIR}/lib.sh"` works in the container.)

- [ ] **Step 6: Syntax-check and smoke-test `backup.sh` in S3 mode with stubs**

Create `backup/tests/test_backup_sh.sh`:

```bash
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
# Stubs: docker emits dump bytes / pretends container ops succeed; aws verifies size.
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
```

Run: `bash backup/tests/test_backup_sh.sh`
Expected: PASS — `backup.sh parses`, S3-mode run succeeds, no local dir created.

> If the smoke test reveals the script reads `/etc/environment.backup` or other absolute
> paths, the stubbed env above overrides them; `/etc/environment.backup` will not exist in
> the test environment so the guarded `source` is skipped. Do not add real cron/Docker.

- [ ] **Step 7: Commit**

```bash
git add backup/backup.sh backup/Dockerfile backup/tests/test_backup_sh.sh
git commit -m "feat(backup): stream dumps to S3 in backup.sh, drop local staging in S3 mode"
```

---

## Task 6: S3-mode retention (drain instead of local policy)

**Files:**
- Modify: `backup/retention.sh:10-17` (source lib), `backup/retention.sh:52-65` (local section)

- [ ] **Step 1: Source the library**

In `backup/retention.sh`, after the `source /etc/environment.backup` block (after line 9), add:

```bash
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${LIB_DIR}/lib.sh"
```

- [ ] **Step 2: Branch the local retention section**

Replace the local retention loop at `backup/retention.sh:52-65` (`log "Applying retention policy..."` through the end of the `for dir in "${BACKUP_ROOT}"/????-??-??` loop) with:

```bash
log "Applying retention policy..."

# --- Local retention ---
if s3_configured; then
  # S3 mode: new dumps never land locally. Drain any pre-existing local backlog
  # to S3 (verified) and delete it. Keeps unverified dirs for retry.
  log "S3 mode: draining local backlog (if any)..."
  drain_local_backlog
else
  for dir in "${BACKUP_ROOT}"/????-??-??; do
    [ -d "$dir" ] || continue
    dir_date=$(basename "$dir")

    if should_keep "$dir_date"; then
      log "Keeping local: ${dir_date}"
    else
      log "Removing local: ${dir_date}"
      rm -rf "$dir"
    fi
  done
fi
```

Leave the `should_keep` function and the entire S3 retention section (`backup/retention.sh:67-85`) unchanged.

- [ ] **Step 3: Add a smoke test for retention S3 mode**

Create `backup/tests/test_retention_sh.sh`:

```bash
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

finish
```

Run: `bash backup/tests/test_retention_sh.sh`
Expected: PASS — parses, run succeeds, backlog dir drained.

- [ ] **Step 4: Commit**

```bash
git add backup/retention.sh backup/tests/test_retention_sh.sh
git commit -m "feat(backup): drain local backlog in retention.sh S3 mode"
```

---

## Task 7: Stream-restore from S3 in `restore.sh`

**Files:**
- Modify: `backup/restore.sh:9-10` (source lib), `backup/restore.sh:69-158` (download + load phases)

- [ ] **Step 1: Source the library**

In `backup/restore.sh`, after the `source /etc/environment.backup` block (after line 9), add:

```bash
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${LIB_DIR}/lib.sh"
```

- [ ] **Step 2: Add an S3-streaming branch for database discovery**

In `backup/restore.sh`, the block at lines 69-86 downloads from S3 to local when the backup is absent locally. Replace that block with a flag that records whether we will stream from S3 instead of using local files:

```bash
# --- Decide source: local files vs streaming from S3 ---
STREAM_FROM_S3=0
if [ ! -d "${BACKUP_DIR}" ] || [ -z "$(ls -A "${BACKUP_DIR}" 2>/dev/null)" ]; then
  if s3_configured; then
    log "Backup not found locally. Will stream from S3."
    STREAM_FROM_S3=1
  else
    log "ERROR: Backup not found at ${BACKUP_DIR} and S3 not configured."
    exit 1
  fi
fi
```

- [ ] **Step 3: Branch database discovery for the streaming case**

Replace the database-discovery block at `backup/restore.sh:88-109` (from `DATABASES=()` through the `if [ ${#DATABASES[@]} -eq 0 ]` guard) with:

```bash
# --- Determine which databases to restore ---
DATABASES=()
if [ -n "${TARGET_DB}" ]; then
  DATABASES+=("${TARGET_DB}")
elif [ "${STREAM_FROM_S3}" -eq 1 ]; then
  while IFS= read -r dbname; do
    [ -n "${dbname}" ] && DATABASES+=("${dbname}")
  done < <(list_s3_databases "${BACKUP_DATE}")
else
  for dump in "${BACKUP_DIR}"/*.dump; do
    [ -f "$dump" ] || continue
    DATABASES+=("$(basename "$dump" .dump)")
  done
fi

if [ ${#DATABASES[@]} -eq 0 ]; then
  log "ERROR: No databases found for ${BACKUP_DATE} (local or S3)."
  exit 1
fi
```

- [ ] **Step 4: Branch the load phase**

Replace the load loop at `backup/restore.sh:144-158` (`LOAD_FAILED=0` through the end of the load `for` loop) with:

```bash
# --- Load each database ---
LOAD_FAILED=0
for db in "${DATABASES[@]}"; do
  log "Loading database: ${db}..."
  if [ "${STREAM_FROM_S3}" -eq 1 ]; then
    if stream_load_from_s3 "${db}" "${BACKUP_DATE}"; then
      log "  OK: ${db} (streamed from S3)"
    else
      log "  FAILED: ${db}"
      LOAD_FAILED=1
    fi
  else
    if docker run --rm \
      -v "${HOST_DATA_DIR}:/data" \
      -v "${HOST_BACKUP_DIR}/${BACKUP_DATE}:/backups" \
      "${NEO4J_ADMIN_IMAGE}" \
      neo4j-admin database load "${db}" --from-path=/backups --overwrite-destination=true 2>&1; then
      log "  OK: ${db}"
    else
      log "  FAILED: ${db}"
      LOAD_FAILED=1
    fi
  fi
done
```

Leave the confirmation prompt, container stop/start, and ownership-fix logic unchanged.

- [ ] **Step 5: Syntax-check restore.sh**

Create `backup/tests/test_restore_sh.sh`:

```bash
#!/bin/bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/helpers.sh"

echo "syntax: restore.sh"
bash -n "${HERE}/../restore.sh"; assert_success $? "restore.sh parses"

finish
```

Run: `bash backup/tests/test_restore_sh.sh`
Expected: PASS — `restore.sh parses`.

> Restore is interactive (confirmation prompt, real container ownership fix), so its
> end-to-end verification is the manual MinIO round-trip in Task 8 rather than a stub smoke
> test. The streaming and discovery functions it calls are already unit-tested in Task 4.

- [ ] **Step 6: Commit**

```bash
git add backup/restore.sh backup/tests/test_restore_sh.sh
git commit -m "feat(backup): stream-restore from S3 via --from-stdin in restore.sh"
```

---

## Task 8: Documentation + full verification

**Files:**
- Modify: `README.md`
- Create: `backup/tests/run_all.sh`

- [ ] **Step 1: Add a test runner**

Create `backup/tests/run_all.sh`:

```bash
#!/bin/bash
# Run all backup shell tests. Exits non-zero if any suite fails.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
rc=0
for t in test_lib.sh test_backup_sh.sh test_retention_sh.sh test_restore_sh.sh; do
  echo "=== ${t} ==="
  bash "${HERE}/${t}" || rc=1
done
exit ${rc}
```

- [ ] **Step 2: Run the full suite**

Run: `bash backup/tests/run_all.sh`
Expected: PASS — every suite prints `Ran N, failed 0`; overall exit 0.

- [ ] **Step 3: Document the streaming behaviour in README**

In `README.md`, in the backup section, add a subsection (place it after the existing backup/S3 configuration text):

```markdown
### Backup storage modes

The backup service chooses a mode automatically from your S3 configuration:

- **S3 mode** — when both `S3_BUCKET` and `S3_ENDPOINT` are set. Each database dump is
  **streamed directly to S3** (`neo4j-admin database dump --to-stdout | aws s3 cp -`) and
  never written to local disk. Uploads use `--expected-size` so large databases upload as
  correctly-sized multipart objects, and each upload is verified by comparing the bytes
  streamed against the resulting S3 object size. A failed or truncated upload is deleted
  from S3 and the previous day's backup is left untouched. Any pre-existing local backups
  are uploaded to S3 and then removed, so the local disk no longer fills up.
- **Local mode** — when S3 is not configured. Dumps are written to `HOST_BACKUP_DIR` and
  pruned by the local retention policy (7 days daily, 28 days weekly, 365 days monthly).

The S3 connection itself is unchanged: the same `S3_BUCKET`, `S3_ENDPOINT`, and `AWS_*`
credentials and the same `aws s3 ... --endpoint-url` mechanism are used, so any
S3-compatible provider (AWS S3, Backblaze B2, Cloudflare R2, MinIO, DigitalOcean Spaces)
works as before.

Restore (`restore.sh <date> [database]`) automatically streams from S3 with
`neo4j-admin database load --from-stdin` when the backup is not present locally.
```

- [ ] **Step 4: Manual end-to-end verification against a real S3-compatible endpoint**

This validates stream purity (no log bytes corrupt the dump) and multipart upload, which
stubs cannot. Run against MinIO or the configured endpoint with a small throwaway DB:

```bash
# Build and start the backup container per the project's normal compose workflow, then:
docker exec <backup-container> /usr/local/bin/backup.sh
# Confirm: object exists and is non-empty
aws s3 ls "s3://${S3_BUCKET}/$(date +%F)/" --endpoint-url "${S3_ENDPOINT}"
# Confirm: the uploaded object is a valid archive (proves stream was not corrupted)
aws s3 cp "s3://${S3_BUCKET}/$(date +%F)/neo4j.dump" - --endpoint-url "${S3_ENDPOINT}" \
  | docker run --rm -i neo4j/neo4j-admin:5.26-community-bullseye \
      neo4j-admin database load neo4j --from-stdin --info
# Confirm: no local backup directory was created
ls -la "${HOST_BACKUP_DIR}" 2>/dev/null
```

Expected: object listed and non-empty; `--info` prints valid file count/byte count/format;
no new local date directory under `HOST_BACKUP_DIR`.

- [ ] **Step 5: Commit**

```bash
git add README.md backup/tests/run_all.sh
git commit -m "docs(backup): document S3 streaming backup mode; add test runner"
```

---

## Self-Review Notes

- **Spec coverage:** streaming dump (Tasks 2, 5), `--expected-size` (Task 2), byte-count
  integrity + partial cleanup (Task 2), automatic S3-mode switch (Tasks 5–7 via
  `s3_configured`), backlog drain (Tasks 3, 6), restore symmetry (Tasks 4, 7), local-only
  mode preserved (Task 5 `else` branch, Task 6 `else` branch), stream-purity check (Task 8
  manual verification), unchanged S3 connection logic (no new vars; same `--endpoint-url`).
- **Names** are consistent with the library contract table (`s3_configured`,
  `estimate_dump_size`, `s3_object_size`, `stream_dump_to_s3`, `drain_local_backlog`,
  `list_s3_databases`, `stream_load_from_s3`; vars `NEO4J_ADMIN_IMAGE`, `DATA_DIR`,
  `BACKUP_ROOT`).
- **Portability:** `du -sk` (busybox + BSD), no `mapfile`/associative arrays, `mktemp` with
  explicit templates — tests run on macOS bash 3.2 and in the Alpine container.
