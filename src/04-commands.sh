#!/usr/bin/env bash
#
# Commands for the application command line

# ---------------------------
# Run all tasks (-a option)
# ---------------------------

# sets all tasks to run
# reads the tasks passed by the user or if option -a
bk_cmd_all_runnable_tasks() {
  local cfg_file="${1:-$BK_CONFIG}"
  local skip=

  TASKS=()
  fn_debug "Searching for runnable tasks...(used option -a)"

  while IFS= read -r sec; do
    [[ -z "${sec}" ]] && continue
    # check if its in the ignore list
    fn_in_array "$sec" "${IGNORE_SECTIONS[@]}" && continue
    # check if its to skip
    skip="$(fn_ini_get "${cfg_file}" "${sec}" "Skip")"
    fn_boolean "${skip,,}" || TASKS+=("$sec")
  done < <(fn_ini_list_sections "${cfg_file}")

  fn_debug "Tasks loaded:" "${TASKS[@]}"
}



# ---------------------------
# Test Environment
# ---------------------------
bk_cmd_test_env() {
  return 0
}


# ---------------------------
# List Tasks
# ---------------------------
# bk_cmd_list_tasks: list task sections and their descriptions.
# Usage: bk_cmd_list_tasks <config_file>
# Output format:
#   <section>  <description>
bk_cmd_list_tasks() {
  local cfg_file="$1"
  local sec desc
  cat <<EOF
${SCRIPT_NAME} - BackupFire Runner (${SCRIPT_VERSION})

DESCRIPTION
  backupfire executes "tasks" defined in an INI config file.
  Each task is a section like [pictures] with keys like Type, From, To.

CONFIG FILE:
  $BK_CONFIG

AVALIABLE TASKS
EOF
  # fn_ini_list_sections returns newline-separated section names.
  while IFS= read -r sec; do
    [[ -z "${sec}" ]] && continue
    fn_in_array "$sec" "${IGNORE_SECTIONS[@]}" && continue
    desc="$(fn_ini_get "${cfg_file}" "${sec}" "Description")"
    [[ -z "$desc" ]] && desc="(no description found)"
    fn_msg '  %-20s %s\n' "${sec}" "${desc:-}"
  done < <(fn_ini_list_sections "${cfg_file}")
}


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
