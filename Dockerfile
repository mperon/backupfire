# syntax=docker/dockerfile:1.6
#
# Alpine base with GNU coreutils (date -d, etc.)
FROM alpine:3.20

# Install only what your script needs:
# - bash: script uses bashisms
# - postgresql-client: provides pg_dump
# - openssl: encryption (rand, pkeyutl, enc)
# - rclone: remote upload
# - perl: used by _readlinkf() abs_path
# - ca-certificates: TLS for rclone
# - dcron: scheduling inside the container
# - coreutils: GNU date for date -d
# - gzip, tar, findutils: compression/packaging + cleanup
# - su-exec: drop privileges safely (gosu equivalent on Alpine)
RUN apk add --no-cache \
  bash \
  postgresql-client \
  openssl \
  rclone \
  perl \
  ca-certificates \
  dcron \
  coreutils \
  gzip \
  tar \
  findutils \
  su-exec

# Create an unprivileged user/group "pgbackup"
# - Use a fixed UID/GID to make host volume permissions easier to manage (optional but recommended)
ARG PG_UID=10001
ARG PG_GID=10001
RUN addgroup -g "${PG_GID}" -S backup \
  && adduser -S -D -h /home/backup -s /bin/bash -u "${PG_UID}" -G backup backup \
  && mkdir -p /app /app/data /app/config \
  && chown -R backup:backup /app /home/backup \
  && chmod -R u+rwX,g+rwX /app /home/backup

# Workdir is the "app root"
WORKDIR /app

# Default paths (can be overridden via -e)
ENV BK_DEST=/app/data
ENV BK_CONFIG_DIR=/app/config

# If BK_CRON is set (cron expression: "m h dom mon dow"), container runs scheduled backups
# Example: BK_CRON="0 2 * * *"
ENV BK_CRON=""

# Copy your app/script into /app
COPY backupfire.sh /app/backupfire
COPY backupfire_lib.sh /app/backupfire_lib.sh
COPY docker-entrypoint.sh /app/docker-entrypoint.sh

# Make scripts executable
RUN chmod 755 /app/*.sh \
  && chown -R backup:backup /app /home/pgbackup

# Declare mount points for persistence/config injection
VOLUME ["/app/data", "/app/config"]

# Entrypoint decides: run once vs cron mode
ENTRYPOINT ["/app/docker-entrypoint.sh"]

# Default: run once now
CMD ["run"]

# 5) switch to non-root for runtime
USER backup
