#!/bin/bash
set -euo pipefail

# Export environment variables to a file so cron jobs can source them
# (cron does not inherit the container's environment)
env | grep -E '^(AWS_|S3_|HOST_|COMPOSE_|BACKUP_|DOCKER_HOST)' > /etc/environment.backup || true

# Create cron job - run at 2:00 AM daily
echo "0 2 * * * /usr/local/bin/backup.sh >> /var/log/backup.log 2>&1" > /etc/crontabs/root

echo "$(date '+%Y-%m-%d %H:%M:%S') Backup service started. Cron scheduled for 2:00 AM daily."
echo "Manual trigger: docker exec <container> /usr/local/bin/backup.sh"

# Safety watchdog: ensure neo4j is running every 5 minutes
# Guards against the backup script crashing mid-run and leaving neo4j stopped
(
  COMPOSE_PROJECT="${COMPOSE_PROJECT:-neo4j}"
  NEO4J_SERVICE="${NEO4J_SERVICE:-neo4j}"
  CONTAINER="${BACKUP_NEO4J_CONTAINER:-${COMPOSE_PROJECT}-${NEO4J_SERVICE}-1}"

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
