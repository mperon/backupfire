#!/usr/bin/env bash
#
# Hooks

# ---------------------------
# Hook (Before/After) execution
# ---------------------------

# allow to run multiple hooks like: After, After1 ..
bk_hook_run() {
  local moment="$1"

  for i in "" $(seq 1 9); do
    key="${moment}${i}"
    value="${cfg[${key}]:-}"
    value="${value// /}"
    if [[ -n "${value}" ]]; then
      if ! bk_hook_run_internal "$key"; then
        return 1
      fi
    fi
  done
  return 0
}

# bk_hook_run: run Before/After commands from config.
#
# Supports:
# - external executables (absolute path),
# - or built-in hook commands: checkSize, countFiles
#
# The config string can use placeholders like %From%, %To%, %Name%, etc.
# Usage: bk_hook_run Before|After
bk_hook_run_internal() {
  local moment="$1"
  local hook_str=""
  hook_str="${cfg[$moment]:-}"

  [[ -z "${hook_str// }" ]] && return 0

  fn_debug "Running $moment Hook:" "$hook_str"

  # Do not allow calling private functions by prefix (basic guard).
  if [[ "${hook_str:0:3}" == "fn_" ||  "${hook_str:0:3}" == "bk_" ]]; then
    fn_error "[${cfg[Name]}][$moment] Hook cannot execute private function-like names: $hook_str"
    return 1
  fi

  # Expand ~ and ./ (./ means relative to From).
  hook_str="${hook_str/#\~\//${HOME}/}"
  hook_str="${hook_str/#\.\//${cfg[From]}/}"

  # Replace %KEY% placeholders from cfg.
  local k
  for k in "${!cfg[@]}"; do
    hook_str="${hook_str//%${k}%/${cfg[$k]}}"
  done

  # Split to argv array without using eval.
  local -a cmdArr
  fn_cmdline_to_array "cmdArr" "$hook_str"
  [[ ${#cmdArr[@]} -eq 0 ]] && return 0

  # Resolve hook command.
  local cmd="${cmdArr[0]}"
  if [[ -x "$cmd" && -f "$cmd" ]]; then
    : # external executable
  else
    case "$cmd" in
      checkSize)  cmdArr[0]="bk_hook_check_size";;
      countFiles) cmdArr[0]="bk_hook_count_files";;
      *)
        fn_error "Hook command not found: $cmd"
        return 1
        ;;
    esac
  fi
  fn_debug "Running ${moment} hook for ${cfg[Name]}: ${hook_str}"

  # Provide context env vars for the hook.
  local From="${cfg[From]}" To="${cfg[To]}" Name="${cfg[Name]}" Type="${cfg[Type]}" Moment="$moment"
  export From To Name Type Moment

  "${cmdArr[@]}"
  local ret=$?

  unset From To Name Type Moment
  return "$ret"
}

# bk_hook_check_size: built-in hook that compares folder size.
# Usage (in config): Before=checkSize "%From%" ">" 10mb
bk_hook_check_size() {
  local folder="$1" oper="$2" size="$3"

  if [[ -z "${folder// }" || ! -d "$folder" ]]; then
    fn_error "[${cfg[Name]}] checkSize: Folder does not exist: $folder"
    return 1
  fi
  if [[ -z "$oper" ]]; then
    fn_error "[${cfg[Name]}] checkSize: Operator is required."
    return 1
  fi

  local size_bytes
  size_bytes="$(fn_human_to_bytes "$size" 2>/dev/null || true)"
  if [[ -z "${size_bytes// }" ]]; then
    fn_error "[${cfg[Name]}] checkSize: Invalid size: $size"
    return 1
  fi

  if ! fn_cmd_exists du cut; then
    fn_error "[${cfg[Name]}] checkSize: du/cut not available."
    return 1
  fi

  local folder_size
  folder_size=$(dir_du_bytes "$folder")
  fn_number_compare "$folder_size" "$oper" "$size_bytes"
}

# bk_hook_count_files: built-in hook that compares number of files (find | wc -l).
# Usage (in config): After=countFiles "%To%" ">=" 1000
bk_hook_count_files() {
  local folder="$1" oper="$2" count="$3"

  if [[ -z "${folder// }" || ! -d "$folder" ]]; then
    fn_error "[${cfg[Name]}] countFiles: Folder does not exist: $folder"
    return 1
  fi
  if [[ -z "$oper" ]]; then
    fn_error "[${cfg[Name]}] countFiles: Operator is required."
    return 1
  fi

  count="${count//[^0-9]/}"
  if [[ -z "${count// }" ]]; then
    fn_error "[${cfg[Name]}] countFiles: Invalid count: $count"
    return 1
  fi

  if ! fn_cmd_exists find wc; then
    fn_error "[${cfg[Name]}] countFiles: find/wc not available."
    return 1
  fi

  local found
  found="$(find "${folder}" 2>/dev/null | wc -l | tr -d ' ')"
  fn_number_compare "$found" "$oper" "$count"
}
