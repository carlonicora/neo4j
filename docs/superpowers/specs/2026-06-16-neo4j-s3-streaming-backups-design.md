# Neo4j S3 Streaming Backups — Design

**Date:** 2026-06-16
**Status:** Approved (design), pending implementation plan
**Author:** Carlo Nicora (with Claude)

## Problem

Neo4j backups are always written to local disk first and only then uploaded to S3.
`retention.sh` then keeps local copies under the same policy as S3 (all backups for
7 days, Sundays for 28 days, 1st-of-month for 365 days), regardless of whether S3 is
configured or whether the upload succeeded.

Two consequences:

1. **Local disk fills up.** Even with S3 configured and working, local copies accumulate
   for at least a week (plus weeklies/monthlies). On a server with a **large** database
   this exhausts disk and crashes the server.
2. **Local disk must be large enough to stage a full dump.** The dump is written to disk
   in full before upload, so the server needs free space ≥ the dump size just to run a
   backup.

## Goals

- Eliminate the local-disk requirement for backups when S3 is configured: stream dumps
  straight to S3 so nothing is staged on disk.
- S3 becomes the single source of truth; local disk retains nothing that is safely in S3.
- A backup is only considered done when its bytes are verified present in S3.
- A failed upload never destroys a previously good backup.
- Clear the existing local backlog that is already filling the disk.

## Non-Goals / Explicit Constraints

- **Do NOT change which S3 is used or how we connect to it.** The S3 connection logic is
  unchanged: same `S3_BUCKET`, `S3_ENDPOINT`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
  `AWS_DEFAULT_REGION`; same `aws s3 ... --endpoint-url "${S3_ENDPOINT}"` mechanism against
  the existing **S3-compatible** endpoint.
- Do **not** use neo4j-admin's native `--to-path=s3://` / `--from-path=s3://`. That path is
  AWS-only and may not accept a custom endpoint. We keep the `aws` CLI + `--endpoint-url`.
- No new configuration variables. Behaviour switches automatically on whether
  `S3_BUCKET` + `S3_ENDPOINT` are set (matching the existing convention).
- Local-only mode (no S3 configured) is preserved exactly as today.

## Verified Facts

Confirmed against `neo4j/neo4j-admin:5.26-community-bullseye`:

- `neo4j-admin database dump <db> --to-stdout` — writes the archive to standard output.
- `neo4j-admin database load <db> --from-stdin` — reads the archive from standard input.
- The backup container (`backup/Dockerfile`) is `docker:27-cli` + `bash`, `aws-cli`, `tini`,
  and already mounts the Neo4j data volume at `/data` (used by `backup.sh` to discover
  databases). `du`/`wc` (busybox) are available for size estimation and byte counting.

## Design

### Mode selection (unchanged convention)

| Mode | Trigger | Behaviour |
|------|---------|-----------|
| **Local-only** | `S3_BUCKET` / `S3_ENDPOINT` not set | Current behaviour, untouched: dump to `/backups/<date>` + 7/28/365 local retention. |
| **S3-only (new)** | `S3_BUCKET` + `S3_ENDPOINT` set | Stream each dump straight to S3; nothing staged on local disk; S3 retention only. |

### Backup flow — S3-only mode (`backup/backup.sh`)

1. Stop Neo4j and discover databases (unchanged: `backup.sh:51-84`).
2. For each database, **estimate the dump size** from the on-disk database directory
   (safe over-estimate, since the dump is compressed):
   ```bash
   EST_BYTES=$(du -sb "/data/databases/${db}" | cut -f1)
   ```
3. **Stream the dump to S3** — never lands on disk:
   ```bash
   set -o pipefail
   docker run --rm -v "${HOST_DATA_DIR}:/data" \
     neo4j/neo4j-admin:5.26-community-bullseye \
     neo4j-admin database dump "${db}" --to-stdout \
     | tee >(wc -c > "${SIZE_FILE}") \
     | aws s3 cp - "s3://${S3_BUCKET}/${TODAY}/${db}.dump" \
         --endpoint-url "${S3_ENDPOINT}" \
         --expected-size "${EST_BYTES}" \
         --no-progress
   ```
   - `--endpoint-url "${S3_ENDPOINT}"` — **same S3 connection as today.**
   - `--expected-size` — required so multipart upload sizes its parts correctly; without
     it, uploads beyond ~80 GB hit the 10,000-part limit and fail. Essential at this scale.
4. **Verify integrity** before treating the dump as done:
   - `set -o pipefail` ⇒ a failed `neo4j-admin dump` fails the whole pipeline.
   - Compare bytes streamed (`${SIZE_FILE}` from `wc -c`) against the S3 object size
     reported by `aws s3 ls "s3://${S3_BUCKET}/${TODAY}/${db}.dump" --endpoint-url …`.
   - **Match** ⇒ success. **Mismatch or pipeline failure** ⇒ delete the partial object
     (`aws s3 rm …`), mark this DB failed (`DUMP_FAILED=1`), and continue with other DBs.
     Previous days' S3 backups are never touched, so a failed run is non-destructive.
5. Restart Neo4j (always, even on failure — unchanged: `backup.sh:103-109`).
6. Apply retention via `retention.sh`.

> **Stream purity check (verify in testing):** confirm `neo4j-admin … --to-stdout` writes
> *only* the archive bytes to stdout and all log lines to stderr, so logging cannot corrupt
> the piped dump. If any log text leaks to stdout, redirect/suppress it before the pipe.

### Retention (`backup/retention.sh`)

- **S3 retention:** unchanged (7d / 28d-Sunday / 365d-1st applied to S3 prefixes,
  `retention.sh:67-83`).
- **Local retention in S3-only mode:** new dumps never land locally, so there is nothing
  to expire under the old policy. The old 7/28/365 local policy applies **only** in
  local-only mode.
- **Backlog drain (one-time, ongoing safety net):** in S3-only mode, for each pre-existing
  local `YYYY-MM-DD` directory (e.g. `data-backup/2026-03-10`):
  1. Upload it to S3 with the existing `aws s3 cp --recursive --endpoint-url …` mechanism.
  2. Verify it landed (object count under the prefix ≥ local file count).
  3. **Verified** ⇒ `rm -rf` the local directory. **Not verified** ⇒ keep it and log a
     warning; retried next run.
  This clears the disk that is already full and self-heals if S3 is temporarily down.

### Restore flow (`backup/restore.sh`)

Mirror the streaming approach in S3-only mode:

```bash
aws s3 cp "s3://${S3_BUCKET}/${BACKUP_DATE}/${db}.dump" - \
    --endpoint-url "${S3_ENDPOINT}" --no-progress \
  | docker run --rm -i -v "${HOST_DATA_DIR}:/data" \
      neo4j/neo4j-admin:5.26-community-bullseye \
      neo4j-admin database load "${db}" --from-stdin --overwrite-destination=true
```

- Note `docker run -i` so the container receives stdin.
- If a backup *is* present locally (local-only mode, or a retained backlog dir), keep the
  existing file-based `--from-path` path (`restore.sh:144-158`).
- Preserve the existing confirmation prompt, Neo4j stop/start handling, and post-load
  ownership fix (`restore.sh:115-168`).

### Failure semantics summary

| Situation | Result |
|-----------|--------|
| Dump process errors mid-stream | `pipefail` fails the run; partial S3 object deleted; prior backups intact; DB marked failed. |
| Byte-count mismatch | Partial S3 object deleted; DB marked failed; prior backups intact. |
| S3 unreachable | Run fails for that DB; nothing deleted; backlog (if any) retained and retried next run. |
| One DB of several fails | Other DBs still attempted; non-zero exit reflects the failure. |

## Testing

Use a local S3-compatible target (MinIO, or the configured endpoint) with a small
throwaway database:

1. **Happy path:** dump streams to S3, lands intact, byte-count verification passes, no
   local file is created.
2. **`--expected-size`:** present and derived from the DB directory size.
3. **Stream purity:** the uploaded object is a valid archive (`neo4j-admin database load
   --info --from-stdin`), proving no log text corrupted the stream.
4. **Injected failure:** force the dump to fail mid-stream; assert the partial S3 object is
   removed and the previous day's backup still exists (non-destructive).
5. **Restore round-trip:** stream the object back via `--from-stdin` and verify data.
6. **Backlog drain:** seed a local `YYYY-MM-DD` dir; assert it uploads, verifies, and is
   deleted locally; assert a failed upload keeps it.
7. **Local-only mode:** with S3 unset, behaviour is unchanged (dump to disk + 7/28/365).

## Affected Files

- `backup/backup.sh` — streaming dump path in S3-only mode; integrity verification.
- `backup/retention.sh` — S3-only local handling + backlog drain; local-only path preserved.
- `backup/restore.sh` — streaming `--from-stdin` restore in S3-only mode.
- Tests — new shell-level tests against an S3-compatible target / stubs.
- Possibly `README.md` — document the streaming behaviour and zero-local-disk guarantee.
