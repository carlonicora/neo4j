#!/bin/bash
set -euo pipefail

# Export environment variables to a file so cron jobs can source them
# (cron does not inherit the container's environment)
# shellcheck source=/dev/null
source /usr/local/bin/lib.sh
write_backup_env_file /etc/environment.backup || true

# Create cron job on BACKUP_SCHEDULE (default 0 2 * * *, server timezone).
# An invalid value is rejected and the default is used, so backups still run.
SCHEDULE=$(resolve_backup_schedule "${BACKUP_SCHEDULE:-}" 2>/dev/null) || true
SCHEDULE_ERROR=$(resolve_backup_schedule "${BACKUP_SCHEDULE:-}" 2>&1 >/dev/null) || true
if [ -n "${SCHEDULE_ERROR}" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: BACKUP_SCHEDULE='${BACKUP_SCHEDULE}' rejected: ${SCHEDULE_ERROR}. Using the default '${SCHEDULE}'."
fi
echo "${SCHEDULE} /usr/local/bin/backup.sh >> /var/log/backup.log 2>&1" > /etc/crontabs/root

echo "$(date '+%Y-%m-%d %H:%M:%S') Backup service started. Cron schedule: '${SCHEDULE}' (server timezone)."
echo "Manual trigger: docker exec <container> /usr/local/bin/backup.sh"

# Safety watchdog: ensure neo4j is running every 5 minutes
# Guards against the backup script crashing mid-run and leaving neo4j stopped
(
  COMPOSE_PROJECT="${COMPOSE_PROJECT:-neo4j}"
  NEO4J_SERVICE="${NEO4J_SERVICE:-neo4j}"
  if [ -n "${BACKUP_NEO4J_CONTAINER:-}" ]; then
    CONTAINER="${BACKUP_NEO4J_CONTAINER}"
  else
    CONTAINER=$(docker ps --format '{{.Names}}' | grep "^${NEO4J_SERVICE}" | grep -v backup | head -1)
    if [ -z "${CONTAINER}" ]; then
      CONTAINER="${COMPOSE_PROJECT}-${NEO4J_SERVICE}-1"
    fi
  fi

  while true; do
    sleep 300
    if [ -f /tmp/backup.lock ]; then
      echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] Backup in progress, skipping check."
      continue
    fi
    if ! docker inspect --format='{{.State.Running}}' "${CONTAINER}" 2>/dev/null | grep -q true; then
      echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] Neo4j not running. Attempting restart..."
      docker update --restart=always "${CONTAINER}" 2>/dev/null || true
      docker start "${CONTAINER}" 2>/dev/null || true
    fi
  done
) &

# Run crond in foreground
exec crond -f -l 2
