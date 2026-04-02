# Neo4j (DozerDB) Docker Deployment

Neo4j graph database running [DozerDB](https://dozerdb.org/) (Neo4j Community Edition with enterprise features) on Docker, managed by [Coolify](https://coolify.io/). Includes automated daily backups with retention policy and S3 offsite storage.

## Services

| Service | Description |
|---------|-------------|
| **neo4j** | DozerDB 5.26.3.0 graph database with APOC and GDS plugins |
| **certs-dumper** | Extracts Let's Encrypt certificates from Traefik for Bolt TLS |
| **neo4j-backup** | Automated daily backup with retention and S3 upload |

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
NEO4J_CONTAINER=<actual-container-name>
HOST_DATA_DIR=/data/coolify/applications/<app-id>/neo4j/data
HOST_BACKUP_DIR=/data/coolify/applications/<app-id>/data-backup
```

## Configuration

### Core Variables

| Variable | Description | Required |
|----------|-------------|----------|
| `NEO4J_AUTH` | Neo4j credentials (format: `username/password`) | Yes |
| `SERVICE_FQDN_NEO4J` | Domain for Traefik routing (set by Coolify) | For Coolify |

### Coolify Variables

| Variable | Description | Required |
|----------|-------------|----------|
| `TRAEFIK_PROXY_DIR` | Host path to Traefik proxy dir (default: `./neo4j/ssl` — no-op locally) | For Coolify |
| `NEO4J_CONTAINER` | Exact Neo4j container name (overrides derived name) | For Coolify |

> **Coolify note:** Coolify generates container names like `neo4j-ogw8o0k8c0c0cww0w0w04wgs-141716273331` instead of the standard `neo4j-neo4j-1`. You **must** set `NEO4J_CONTAINER` to the actual container name. Find it with: `docker ps --format "{{.Names}}" | grep neo4j`

### Backup Variables

| Variable | Description | Required |
|----------|-------------|----------|
| `HOST_DATA_DIR` | Absolute host path to `neo4j/data` directory | For backups |
| `HOST_BACKUP_DIR` | Absolute host path to `data-backup` directory | For backups |
| `S3_BUCKET` | S3 bucket name | For S3 upload |
| `S3_ENDPOINT` | S3-compatible endpoint URL | For S3 upload |
| `AWS_ACCESS_KEY_ID` | S3 access key | For S3 upload |
| `AWS_SECRET_ACCESS_KEY` | S3 secret key | For S3 upload |
| `AWS_DEFAULT_REGION` | S3 region (default: `us-east-1`) | No |

If `HOST_DATA_DIR` or `HOST_BACKUP_DIR` are not set, backups are silently skipped. If S3 variables are not set, only local backups are created.

### Finding Host Paths (Coolify)

In the Coolify dashboard, go to your service's settings and look at the volume mounts. The source paths show the host paths. They follow the pattern:

```
/data/coolify/applications/<app-id>/neo4j/data
/data/coolify/applications/<app-id>/data-backup
```

## Backup System

### How It Works

DozerDB is based on Neo4j Community Edition, which does **not** support online backups. The database must be stopped before dumping (see [DozerDB/dozerdb-plugin#61](https://github.com/DozerDB/dozerdb-plugin/issues/61)).

The backup runs daily at **2:00 AM** (server timezone) and follows this sequence:

1. **Discover** all databases by listing `/data/databases/`
2. **Stop** the Neo4j container (temporarily disables `restart: always` policy)
3. **Dump** each database using the `neo4j/neo4j-admin` Docker image
4. **Restart** Neo4j and restore `restart: always` policy (always, even if some dumps fail)
5. **Upload** to S3 (if configured)
6. **Apply** retention policy (local and S3)

A safety watchdog runs every 5 minutes to ensure Neo4j is running, guarding against crashes during backup.

### Retention Policy

| Tier | Rule | Kept for |
|------|------|----------|
| Daily | All backups | 7 days |
| Weekly | Sunday backups | 28 days |
| Monthly | 1st-of-month backups | 365 days |

A single backup can satisfy multiple tiers (e.g., Sunday January 1st counts as daily, weekly, and monthly).

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
Check that `HOST_DATA_DIR` and `HOST_BACKUP_DIR` are set in `.env`. These must be absolute host paths, not container paths.

### Neo4j not restarting after backup
The watchdog checks every 5 minutes and will auto-restart Neo4j, restoring the `restart: always` policy if it was left disabled by a crashed backup. To manually restart:
```bash
docker start <container-name>
docker update --restart=always <container-name>
```

### S3 upload failing
Verify credentials:
```bash
docker compose exec neo4j-backup aws s3 ls s3://<bucket>/ --endpoint-url <endpoint>
```

### Wrong neo4j-admin version
The backup script uses `neo4j/neo4j-admin:5.26-community-bullseye` to match DozerDB 5.26.3.0. If you upgrade DozerDB, update the version in [backup/backup.sh](backup/backup.sh).

### Dump fails for a specific database
Check if the database is corrupted. The backup script continues with remaining databases and logs the failure. Check logs:
```bash
docker compose logs neo4j-backup --since 24h | grep FAILED
```
