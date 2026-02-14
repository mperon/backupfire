#!/usr/bin/env bash
# backupfire.sh - Backup tool
#
# Runs backup "tasks" defined in an INI config file.
#
# Supported Types:
#   - Local  : rsync local->local
#   - Remote : rclone local<->remote
#   - Backup : run a Vault Action (e.g. Database / CopyFiles),
#              then optionally compress and encrypt before copying to destination.
set -o pipefail

docker run --rm --name logmix \
  --log-driver=json-file \
  alpine:3.19 sh -c '
    i=0
    while true; do
      i=$((i+1))
      echo "$(date -Iseconds) INFO stdout line=$i"
      echo "$(date -Iseconds) ERROR stderr line=$i" 1>&2
      sleep 1
    done
  '
