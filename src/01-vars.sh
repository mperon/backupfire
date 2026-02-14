#!/usr/bin/env bash
#
# Constants and global variables
# ---------------------------
# Constants / defaults
# ---------------------------
SCRIPT_VERSION="2.0.1"

# Default config search locations.
CFG_DEFAULT_NAME="default.conf"
CFG_DIRS=("$SCRIPT_DIR/config" "$HOME/config/" "/etc/backupfire")
IGNORE_SECTIONS=("general" "crontab")

# Safety: directories that are almost always a bad destination.
INVALID_DIR_PREFIXES="/etc/,/bin/,/boot/,/dev/,/lib/,/lib32/,/lib64/,/libx32/,/proc/"

# External tools (can be overridden by env vars).
RSYNC_CMD="${RSYNC_CMD:-rsync}"
RCLONE_CMD="${RCLONE_CMD:-rclone}"
OPENSSL_CMD="${OPENSSL_CMD:-openssl}"
POSTGRES_CMD="${POSTGRES_CMD:-pg_dump}"
POSTGRES_CHECK_CMD="${POSTGRES_CHECK_CMD:-psql}"
DOCKER_CMD="${DOCKER_CMD:-docker}"

# Options variables
###############################################################################
BK_ALL=""
BK_DECRYPT="" # action decryption of a specific file or files
BK_DECRYPT_KEY="" # private key to be used
BK_EMAIL="" # Reserved for future (email reporting)
BK_CONFIG="${BK_CONFIG:-}"
RCLONE_CONFIG="${RCLONE_CONFIG:-}"
BK_LIST=""
BK_HELP=""
BK_TEST_ENV=""
BK_GEN_CRON=""

# Positional: requested tasks (section names).
TASKS=() CLEANUP=() UPLOADS=()

# Internal state for dependency resolution.
declare -A RUN_SET=() WALK_SET=() ERR_SET=()

# Task config is loaded into this associative array before each run.
declare -A cfg=()

#current task
CURRENT_TASK=
