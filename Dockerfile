# syntax=docker/dockerfile:1.6

############################
# 1) Build stage (minimal)
############################
FROM alpine:3.23 AS build

RUN apk add --no-cache bash findutils

WORKDIR /src

# Copy only what build.sh needs
COPY build.sh ./build.sh
COPY VERSION VERSION
COPY src/ ./src/

# Build dist/backupfire.sh
RUN bash ./build.sh \
  && test -x dist/backupfire.sh

############################
# 2) Runtime stage
############################
FROM alpine:3.23

RUN apk add --no-cache \
  bash \
  postgresql-client \
  openssl \
  openssh-client \
  rclone \
  perl \
  rsync \
  ca-certificates \
  dcron \
  coreutils \
  gzip \
  tar \
  findutils \
  tini \
  docker-cli

ARG PG_UID=10001
ARG PG_GID=10001
RUN addgroup -g "${PG_GID}" -S backup \
  && adduser -S -D -h /home/backup -s /bin/bash -u "${PG_UID}" -G backup backup \
  && mkdir -p /app /app/data /app/config /app/sources /app/run /etc/backupfire /home/backup/config \
  && chown -R backup:backup /app /home/backup /app/config /home/backup/config /app/sources /app/run /etc/backupfire \
  && chmod -R u+rwX,g+rwX /app /home/backup /app/config /home/backup/config

WORKDIR /app

ENV BK_DEST=/app/data
ENV BK_CONFIG_DIR=/app/config
ENV BK_CONFIG=
ENV BK_CRONFILE=/app/run/backupfire.crontab
ENV RCLONE_CONFIG=
# default commands
ENV RSYNC_CMD=rsync \
  RCLONE_CMD=rclone \
  OPENSSL_CMD=openssl \
  POSTGRES_CMD=pg_dump \
  POSTGRES_CHECK_CMD=psql \
  DOCKER_CMD=docker

# Copy only the built artifact
COPY --from=build /src/dist/backupfire.sh /app/backupfire.sh
COPY LICENSE README.md VERSION /app/

# Entrypoint
COPY docker-entrypoint.sh /app/docker-entrypoint.sh

RUN chmod 755 /app/backupfire.sh /app/docker-entrypoint.sh \
  && chown -R backup:backup /app /home/backup

VOLUME ["/app/data", "/app/config"]

#USER backup

ENTRYPOINT ["/sbin/tini", "--", "/app/docker-entrypoint.sh"]
CMD ["cron"]
