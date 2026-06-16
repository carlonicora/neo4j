FROM docker:27-cli

RUN apk add --no-cache \
    bash \
    aws-cli \
    tini

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY backup.sh /usr/local/bin/backup.sh
COPY retention.sh /usr/local/bin/retention.sh
COPY restore.sh /usr/local/bin/restore.sh
COPY lib.sh /usr/local/bin/lib.sh
COPY tests/ /usr/local/bin/tests/

RUN chmod +x /usr/local/bin/*.sh /usr/local/bin/tests/*.sh

ENTRYPOINT ["tini", "--"]
CMD ["/usr/local/bin/entrypoint.sh"]
