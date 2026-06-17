# Pinned base. The rolling `docker:27-cli` tag resolves to Alpine 3.21, whose current
# package set ships a pyexpat newer than its libexpat, silently breaking `aws` (missing
# symbol XML_SetAllocTrackerActivationThreshold). A broken `aws` makes S3 uploads fail
# and strands backups on local disk. Alpine 3.22 (docker:28-cli) has a consistent set
# where `aws` works; use it, and gate the build so a broken `aws` can never ship.
FROM docker:28-cli

RUN apk add --no-cache \
    bash \
    aws-cli \
    tini

# Build-time gate: fail the build (loudly) if the AWS CLI is broken, instead of
# producing an image that silently fails every S3 operation at 2 AM.
RUN aws --version && python3 -c 'import pyexpat; print("pyexpat OK")'

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY backup.sh /usr/local/bin/backup.sh
COPY retention.sh /usr/local/bin/retention.sh
COPY restore.sh /usr/local/bin/restore.sh
COPY lib.sh /usr/local/bin/lib.sh
COPY tests/ /usr/local/bin/tests/

RUN chmod +x /usr/local/bin/*.sh /usr/local/bin/tests/*.sh

ENTRYPOINT ["tini", "--"]
CMD ["/usr/local/bin/entrypoint.sh"]
