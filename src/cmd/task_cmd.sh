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
