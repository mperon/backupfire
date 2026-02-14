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

# SCRIPT NAME
SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"

# Resolve script directory (safe when invoked via symlink).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

SRC_DIR="${SCRIPT_DIR}/src"

# Collect files once (recursive), sorted for deterministic output
# Works on macOS + Alpine
mapfile -t files < <(find "$SRC_DIR" -type f -name '*.sh' -print | sort | uniq)

# Append cleaned content
for f in "${files[@]}"; do
  source "$f"
done

# run main function
bk_main "$@"
