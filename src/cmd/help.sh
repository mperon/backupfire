#!/usr/bin/env bash
#
# Commands for the application command line

# ---------------------------
# Help / usage
# ---------------------------
# print_global_help: show full usage, options, and (when possible) tasks.
# Usage: print_global_help
bk_cmd_print_help() {
  cat <<EOF
${SCRIPT_NAME} - BackupFire Runner (${SCRIPT_VERSION})

SYNOPSIS
  ${SCRIPT_NAME} [options] <task> [task2 ...]
  ${SCRIPT_NAME} [options] -a

DESCRIPTION
  backupfire executes "tasks" defined in an INI config file.
  Each task is a section like [pictures] with keys like Type, From, To.

CONFIG
  (default)  ./config/${CFG_DEFAULT_NAME}
             ~/.config/backupfire/${CFG_DEFAULT_NAME} (if present)
             /etc/backupfire/${CFG_DEFAULT_NAME} (if present)

  -c <file>  use a specific config file

OPTIONS
  -a         run all tasks found in config (Ignore ones with Skip=True)
  -c <file>  config file path (or just a filename searched in config dirs)
  -d         debug (verbose logs)
  -D <file>  Decrypt a previously encrypted file.
  -k <key>   Custom key to be used to decrypt (only works with decrypt)
  -l         list tasks + short description
  -T         test environment (check required commands), then exit
  -C         generate cron jobs based in the configuration
  -h         show this help

EXAMPLES
  ${SCRIPT_NAME} -c default.conf pictures remote
  ${SCRIPT_NAME} -a -n    # show what would run
  ${SCRIPT_NAME} -T       # verify dependencies
EOF
}
