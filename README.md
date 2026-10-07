# Neo4j (DozerDB) Docker Deployment

Neo4j graph database running [DozerDB](https://dozerdb.org/) (Neo4j Community Edition with enterprise features) on Docker, managed by [Coolify](https://coolify.io/). Includes automated daily backups with retention policy and S3 offsite storage.

## Services

| Service          | Description                                                   |
| ---------------- | ------------------------------------------------------------- |
| **neo4j**        | DozerDB 5.26.27.0 graph database with APOC, GDS and hot backup plugins |
| **certs-dumper** | Extracts Let's Encrypt certificates from Traefik for Bolt TLS |
| **neo4j-backup** | Automated daily backup with retention and S3 upload           |

## Plugins

APOC is installed at boot by the Neo4j entrypoint (`NEO4J_PLUGINS=["apoc"]`).

OpenGDS is **baked into the image** — [`neo4j-image/Dockerfile`](neo4j-image/Dockerfile) copies `open-gds-2.13.11.jar` into `/plugins`, so the `neo4j` service is built rather than pulled.

The **hot backup plugin** (`neo4j-hot-backup-5.26.27.0.jar`) is baked in the same way. See [Hot Backup Plugin](#hot-backup-plugin).

It cannot be a bind mount. Coolify deploys this repository as a Docker Compose resource, which copies only the transformed compose file and `.env` to the destination host — never the repository. It then pre-creates any missing bind-mount directory, empty. A jar committed in this repo and mounted at `/plugins` therefore never reaches production, and every `gds.*` call fails with `Unknown function 'gds.version'`.

Upgrading OpenGDS: drop the new jar in `neo4j-image/`, update the `COPY` line and the `FROM` tag to a version pair that matches, then redeploy. Plugins are only read at boot, so the container has to restart.

## Hot Backup Plugin

### What it is

DozerDB is Neo4j Community Edition, and Community has no online backup: `neo4j-admin database backup` exists only in Enterprise. Until now the only safe backup was to stop the database, dump it, and start it again, which costs a few minutes of downtime every night.

`neo4j-hot-backup` is a small plugin jar, built from the separate `neo4j-backup` project (its own repository, with sources, tests and a README of its own), that adds the missing piece to Community. It uses the same kernel mechanism Enterprise uses: it forces a checkpoint, blocks further checkpoints while it copies the store files and the transaction log, then releases. The copy is consistent as of the moment the backup started, and the database keeps serving reads and writes the whole time.

The output is a normal `.dump` file. `neo4j-admin database load` and the existing `restore.sh` read it without any change.

### What it does

The plugin adds these procedures. All need admin rights.

| Procedure | What it does |
| --- | --- |
| `CALL backup.database('neo4j')` | Backs up one database. Throws if the database does not exist or is not running. |
| `CALL backup.all()` | Backs up every database, `system` included. Never throws for a single database: each one gets its own row. |
| `CALL backup.databaseTo('neo4j', 'name.dump')` | Backs up one database to `server.backup.directory/<name>`. If that path is an existing FIFO, the dump is streamed into it (the call waits for a reader). Used by the nightly job. Throws on failure. |

Each row has these columns:

| Column | Meaning |
| --- | --- |
| `database` | Database name |
| `path` | Where the dump was written inside the container, e.g. `/var/lib/neo4j/backups/neo4j-20261005-091200.dump` |
| `bytes` | Size of the dump |
| `millis` | How long it took |
| `status` | `ok`, `skipped: not available` (database stopped), or `failed: <reason>` |

Files are named `<database>-<yyyyMMdd-HHmmss>.dump`. A second backup of the same database within the same second fails rather than overwrite; the earlier file is never touched.

### How it is installed here

Three things make it work in this deployment:

- [`neo4j-image/Dockerfile`](neo4j-image/Dockerfile) copies the jar into `/plugins`, next to OpenGDS. It is pinned to the server version in the `FROM` line; when DozerDB is upgraded, rebuild the jar from the `neo4j-backup` project against the new version first.
- [`docker-compose.yml`](docker-compose.yml) lists `backup.*` in `NEO4J_dbms_security_procedures_unrestricted` and `..._allowlist`. The procedures touch kernel internals, so Neo4j refuses to load them sandboxed, exactly like APOC.
- [`docker-compose.yml`](docker-compose.yml) mounts `./data-backup` at `/var/lib/neo4j/backups`, the plugin's output directory (`server.backup.directory`). That is the same host folder the backup container uses, so dumps appear under `HOST_BACKUP_DIR` on the host.

Plugins load at boot, so the `neo4j` service must be rebuilt and restarted after these changes.

### Manual use

Run a backup of everything while Neo4j is up:

```bash
docker compose exec neo4j cypher-shell -u neo4j -p <password> "CALL backup.all()"
```

Or just one database:

```bash
docker compose exec neo4j cypher-shell -u neo4j -p <password> "CALL backup.database('neo4j')"
```

The same statements work in Neo4j Browser. Run them against a user database such as `neo4j` (cypher-shell's default), not against `system`, which only accepts admin commands. Check the `status` column of every row: `ok` means the file at `path` is complete and loadable.

The files land in `data-backup/` on the host:

```bash
ls -la data-backup/*.dump
```

To restore one, give it the name `restore.sh` expects (`<database>.dump` inside a date folder) and run the normal restore:

```bash
mkdir -p data-backup/2026-10-05
cp data-backup/neo4j-20261005-091200.dump data-backup/2026-10-05/neo4j.dump
docker compose exec -it neo4j-backup restore.sh 2026-10-05 neo4j
```

Restore still stops Neo4j, loads, and restarts it. The first start after a load runs recovery, which replays the tail of the transaction log that was copied while writes were in flight. That is expected and takes seconds.

### Automatic use

The scheduled job in the `neo4j-backup` container ([`backup/backup.sh`](backup/backup.sh)) uses the plugin. Neo4j is never stopped. Every night at 2:00 AM it:

1. Lists the databases with `SHOW DATABASES` through `cypher-shell`, using the `NEO4J_AUTH` credentials passed to the backup service. A database that is not `online` is logged as `FAILED`.
2. Backs up each online database, one at a time, with `CALL backup.databaseTo(...)`:
   - **S3 mode**: creates a FIFO (`data-backup/.stream-<database>.fifo`), starts `aws s3 cp - s3://<bucket>/<date>/<database>.dump --expected-size <estimate>` reading from it, and has the plugin stream the dump into it. Nothing is written to disk. The estimate comes from the database's store size under `/data`; without it the AWS CLI caps a streamed upload well below a large dump.
   - **Local mode**: the plugin writes `data-backup/.partial-<database>.dump`, which is moved to `data-backup/<date>/<database>.dump` once complete.
3. Checks each database. In S3 mode the upload must succeed and the S3 object size must equal the bytes the plugin wrote. On any failure the S3 object is deleted and any open multipart upload is aborted (local mode: the partial file is deleted). Nothing is kept for a retry. Each call is limited to `BACKUP_DB_TIMEOUT` seconds (default 6 hours).
4. Applies the retention policy, **only if every database succeeded**. Otherwise it logs `Retention skipped: backup failed, nothing deleted` and exits non-zero, so a bad night never removes good backups.

Disk note: S3 mode uses no local disk at all. Local mode needs room for one full set of dumps per kept date.

Trigger it by hand with:

```bash
docker compose exec neo4j-backup /usr/local/bin/backup.sh
```

### Verifying a hot backup

Load the file into a throwaway container and count something you know:

```bash
mkdir -p /tmp/hb && cp data-backup/neo4j-<timestamp>.dump /tmp/hb/neo4j.dump
docker run --rm -v /tmp/hb-data:/data -v /tmp/hb:/backups graphstack/dozerdb:5.26.27.0 \
  neo4j-admin database load neo4j --from-path=/backups --overwrite-destination=true
docker run -d --name hb-check -e NEO4J_AUTH=neo4j/check1234 -v /tmp/hb-data:/data graphstack/dozerdb:5.26.27.0
# wait for it to come up, then:
docker exec hb-check cypher-shell -u neo4j -p check1234 "MATCH (n) RETURN count(n)"
docker rm -f hb-check
```

`neo4j-admin database check` works on the restored data only after that first start, because the store needs recovery first.

### Troubleshooting the plugin

- **`There is no procedure with the name backup.all`**: the jar did not load. `docker compose exec neo4j ls /plugins` must list `neo4j-hot-backup-5.26.27.0.jar`. If it is missing, the service was pulled instead of built; rebuild it.
- **`backup.all is unavailable because it is sandboxed`**: `backup.*` is missing from `NEO4J_dbms_security_procedures_unrestricted`.
- **`server.backup.directory is not a writable directory`**: the `./data-backup` mount is missing or not writable by the `neo4j` user inside the container (uid 7474). On the host, `chmod 777 data-backup` is the blunt fix.
- **`status = failed: ... already exists`**: two backups of the same database in the same second. Run the job once, not in a loop.

## Quick Start

### Local Development

```bash
cp .env.example .env
# Edit .env with your credentials (NEO4J_AUTH at minimum)
docker compose up -d
```

The `certs-dumper` service runs as a no-op locally (no Traefik certificates to extract). Bolt TLS will be configured but use self-signed certs or fail gracefully with `tls_level=OPTIONAL`.

### Coolify Deployment

Set these additional variables in the Coolify environment:

```env
TRAEFIK_PROXY_DIR=/data/coolify/proxy
BACKUP_NEO4J_CONTAINER=<actual-container-name>
HOST_DATA_DIR=/data/coolify/applications/<app-id>/neo4j/data
HOST_BACKUP_DIR=/data/coolify/applications/<app-id>/data-backup
```

## Configuration

### Core Variables

| Variable             | Description                                     | Required    |
| -------------------- | ----------------------------------------------- | ----------- |
| `NEO4J_AUTH`         | Neo4j credentials (format: `username/password`) | Yes         |
| `SERVICE_FQDN_NEO4J` | Domain for Traefik routing (set by Coolify)     | For Coolify |

### Coolify Variables

| Variable                 | Description                                                             | Required    |
| ------------------------ | ----------------------------------------------------------------------- | ----------- |
| `TRAEFIK_PROXY_DIR`      | Host path to Traefik proxy dir (default: `./neo4j/ssl` — no-op locally) | For Coolify |
| `BACKUP_NEO4J_CONTAINER` | Exact Neo4j container name (overrides derived name)                     | For Coolify |

> **Coolify note:** Coolify generates container names like `neo4j-ogw8o0k8c0c0cww0w0w04wgs-141716273331` instead of the standard `neo4j-neo4j-1`. You **must** set `BACKUP_NEO4J_CONTAINER` to the actual container name. Find it with: `docker ps --format "{{.Names}}" | grep neo4j`

### Backup Variables

| Variable                | Description                                   | Required      |
| ----------------------- | --------------------------------------------- | ------------- |
| `HOST_DATA_DIR`         | Absolute host path to `neo4j/data` directory  | For restore   |
| `HOST_BACKUP_DIR`       | Absolute host path to `data-backup` directory | For backups   |
| `BACKUP_RETENTION`      | Which backups to keep, e.g. `daily=7,weekly=4,monthly=12` (see [Retention Policy](#retention-policy)) | No, has default |
| `BACKUP_DB_TIMEOUT`     | Max seconds for one database's backup (default `21600`, 6 hours) | No            |
| `S3_BUCKET`             | S3 bucket name                                | For S3 upload |
| `S3_ENDPOINT`           | S3-compatible endpoint URL                    | For S3 upload |
| `AWS_ACCESS_KEY_ID`     | S3 access key                                 | For S3 upload |
| `AWS_SECRET_ACCESS_KEY` | S3 secret key                                 | For S3 upload |
| `AWS_DEFAULT_REGION`    | S3 region (default: `us-east-1`)              | No            |

If neither `HOST_BACKUP_DIR` nor S3 is set, backups are silently skipped. If S3 variables are not set, only local backups are created. `HOST_DATA_DIR` is still needed by `restore.sh`. The backup service also needs `NEO4J_AUTH` (passed through from `.env`) to call the backup procedures.

### Finding Host Paths (Coolify)

In the Coolify dashboard, go to your service's settings and look at the volume mounts. The source paths show the host paths. They follow the pattern:

```
/data/coolify/applications/<app-id>/neo4j/data
/data/coolify/applications/<app-id>/data-backup
```

## Backup System

### How It Works

DozerDB is Neo4j Community Edition, which has no online backup of its own. The [Hot Backup Plugin](#hot-backup-plugin) adds one, so the nightly job runs with the database online.

The backup runs daily at **2:00 AM** (server timezone) and follows this sequence:

1. **List** the databases with `SHOW DATABASES`; any that is not online is a failure
2. **Back up** each online database with `CALL backup.databaseTo(...)` while Neo4j keeps serving queries: streamed straight to S3 through a FIFO (no local copy), or filed by date locally
3. **Check** each one; a failed or size-mismatched upload is deleted from S3
4. **Apply** retention policy (local or S3), only when every database succeeded

A safety watchdog still runs every 5 minutes and restarts Neo4j if it is ever found stopped.

### Retention Policy

Which dated backups to keep is set by one variable, `BACKUP_RETENTION`, applied the same way to local date folders and to S3 date prefixes. It is a comma-separated list of rules. Each rule is a calendar window counted back from today, today included:

| Rule | Keeps |
| --- | --- |
| `last=N` | the N newest backups, however old |
| `daily=N` | every backup from the last N calendar days |
| `weekly=N` | the newest backup in each of the last N calendar weeks (Monday to Sunday), the current week included |
| `monthly=N` | the newest backup in each of the last N calendar months, the current month included |
| `yearly=N` | the newest backup in each of the last N calendar years, the current year included |

A backup kept by any rule survives; everything else is deleted. Windows are calendar time, not "N backups": with `daily=14` on 2026-10-07 the window is 2026-09-24 to 2026-10-07, and an older backup is deleted even if some days in the window have none.

Only **complete** backups count. A date is complete when it holds `<database>.dump` for every database Neo4j currently has (the `SHOW DATABASES` list). An incomplete date, for example one where a database failed, never counts towards any rule and is always deleted.

Safety rules:

- Retention runs only after a backup where every database succeeded.
- If the policy would leave no complete backup at all, nothing is deleted and the step fails.
- If the database list cannot be read (Neo4j unreachable), nothing is deleted and the step fails.
- An empty, unparsable or all-zero policy stops the step with an error and deletes nothing.

Examples:

```env
BACKUP_RETENTION=daily=14                              # everything from the last 14 days
BACKUP_RETENTION=daily=7,weekly=4                      # the last 7 days, plus one per week for the last 4 weeks
BACKUP_RETENTION=daily=7,weekly=4,monthly=12,yearly=2  # full GFS, two years deep
```

The default when the variable is unset is `daily=7,weekly=4,monthly=12`.

### S3 Provider Examples

**AWS S3:**

```env
S3_ENDPOINT=https://s3.us-east-1.amazonaws.com
AWS_DEFAULT_REGION=us-east-1
```

**Backblaze B2:**

```env
S3_ENDPOINT=https://s3.us-west-004.backblazeb2.com
AWS_DEFAULT_REGION=us-west-004
```

**Cloudflare R2:**

```env
S3_ENDPOINT=https://<account-id>.r2.cloudflarestorage.com
AWS_DEFAULT_REGION=auto
```

**MinIO:**

```env
S3_ENDPOINT=https://minio.example.com
AWS_DEFAULT_REGION=us-east-1
```

### Backup storage modes

The backup service chooses a mode automatically from your S3 configuration:

- **S3 mode** — when both `S3_BUCKET` and `S3_ENDPOINT` are set. Each dump is streamed
  from the plugin through a FIFO into `aws s3 cp -`: no local copy is ever written. The S3
  object size is compared with the bytes the plugin wrote. A failed or truncated upload is
  deleted from S3 (open multipart uploads are aborted), nothing is kept locally for a retry,
  and the previous days' backups are left untouched because retention does not run.
- **Local mode** — when S3 is not configured. Dumps are written to `HOST_BACKUP_DIR` and
  pruned by the [retention policy](#retention-policy).

The S3 connection itself is unchanged: the same `S3_BUCKET`, `S3_ENDPOINT`, and `AWS_*`
credentials and the same `aws s3 ... --endpoint-url` mechanism are used, so any
S3-compatible provider (AWS S3, Backblaze B2, Cloudflare R2, MinIO, DigitalOcean Spaces)
works as before.

Restore (`restore.sh <date> [database]`) automatically streams from S3 with
`neo4j-admin database load --from-stdin` when the backup is not present locally.

### Verifying S3 backups

To validate the upload end-to-end against your S3-compatible endpoint:

```bash
# Trigger a backup manually inside the backup container:
docker exec <backup-container> /usr/local/bin/backup.sh

# Confirm the object exists and is non-empty:
aws s3 ls "s3://${S3_BUCKET}/$(date +%F)/" --endpoint-url "${S3_ENDPOINT}"

# Confirm the uploaded object is a valid archive (proves the stream was not corrupted):
aws s3 cp "s3://${S3_BUCKET}/$(date +%F)/neo4j.dump" - --endpoint-url "${S3_ENDPOINT}" \
  | docker run --rm -i neo4j/neo4j-admin:5.26-community-bullseye \
      neo4j-admin database load neo4j --from-stdin --info

# Confirm nothing was written locally:
ls -la "${HOST_BACKUP_DIR}" 2>/dev/null
```

Expected: one object per database, non-empty; `--info` prints a valid file count, byte
count, and format; and no `.dump`, `.partial-*` or `.stream-*` file under `HOST_BACKUP_DIR`.

## Manual Operations

### Trigger a Backup Manually

```bash
docker compose exec neo4j-backup /usr/local/bin/backup.sh
```

### Check Backup Logs

```bash
docker compose logs neo4j-backup --since 24h
```

### List Local Backups

```bash
ls -la data-backup/
```

### Restore a Database from Backup

The backup container includes a `restore.sh` script that handles the full restore process — stopping Neo4j, loading the dump, fixing ownership, and restarting.

```bash
# Restore all databases from a specific date
docker compose exec -it neo4j-backup restore.sh 2026-03-01

# Restore only the neo4j database
docker compose exec -it neo4j-backup restore.sh 2026-03-01 neo4j
```

If the backup is not found locally, it will be automatically downloaded from S3 (if configured). The script will ask for confirmation before overwriting any data.

## Troubleshooting

### Backup skipped silently

Check that `HOST_BACKUP_DIR` (or the S3 variables) is set in `.env`. Host paths must be absolute host paths, not container paths.

### Neo4j not running

The backup no longer stops Neo4j. The watchdog still checks every 5 minutes and restarts it if it is found stopped for any reason, restoring the `restart: always` policy. To manually restart:

```bash
docker start <container-name>
docker update --restart=always <container-name>
```

### S3 upload failing

Verify credentials:

```bash
docker compose exec neo4j-backup aws s3 ls s3://<bucket>/ --endpoint-url <endpoint>
```

### `Unknown function 'gds.version'`

GDS did not load. Check the jar is in the image and that the container was restarted after any change:

```bash
docker compose exec neo4j ls -la /plugins
docker compose exec neo4j cypher-shell -u neo4j -p <password> "RETURN gds.version();"
```

`/plugins` should hold `apoc.jar`, `open-gds-2.13.11.jar` and `neo4j-hot-backup-5.26.27.0.jar`. If the jar is missing, the `neo4j` service was pulled instead of built — rebuild it (`docker compose build neo4j`, or a full redeploy in Coolify).

### Wrong neo4j-admin version

`restore.sh` uses `neo4j/neo4j-admin:5.26-community-bullseye` to match DozerDB 5.26.27.0. If you upgrade DozerDB, update `NEO4J_ADMIN_IMAGE` in [backup/lib.sh](backup/lib.sh), and rebuild the hot backup plugin jar for the new version.

### Backup fails for a specific database

The job logs one line per database, `OK: <database> (<bytes> bytes ...)` or `FAILED: <database> (<reason>)`. A database that is not online, a failed `backup.databaseTo` call, a failed upload or a size mismatch are all failures. The script continues with the others, then exits non-zero. Check logs:

```bash
docker compose logs neo4j-backup --since 24h | grep FAILED
```

A failed database's S3 object is deleted, so its date stays incomplete and the next retention run removes it.

### `Retention skipped: backup failed, nothing deleted`

At least one database failed, so retention did not run and no backup was deleted. Fix the failure (see above); the next fully successful run applies retention again, including removing the incomplete date.

### Retention fails with "would leave no complete backup"

No complete backup falls inside any window of `BACKUP_RETENTION`, for example after a long run of failed nights with `daily=N` only. Nothing was deleted. Add a `last=N` rule, or fix the backups so a complete date exists inside the window.

### Old dumps left in `data-backup/` (S3 mode)

Earlier versions wrote dumps to `data-backup/` before uploading and kept them there when an upload failed. The current job never reads or deletes them in S3 mode. Once S3 holds a complete recent backup, delete them by hand (`data-backup/<date>/` folders and loose `*.dump` files).
