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

# Resolve script directory (safe when invoked via symlink).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

source "$SCRIPT_DIR/backupfire.sh"
