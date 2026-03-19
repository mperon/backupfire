#!/usr/bin/env bash
#
# Run tasks

# ---------------------------
# Task runner
# ---------------------------
# bk_validate_action_name: ensure an action section name contains safe characters.
# Usage: bk_validate_action_name <name>
bk_task_validate_name() {
  local task="$1"
  [[ "$task" =~ ^[0-9A-Za-z._-]+$ ]]
}


# bk_task_deps: get the raw Depends string for an task (may be empty).
# Usage: bk_task_deps <task>
bk_task_deps() {
  fn_ini_get "${BK_CONFIG}" "$1" "Depends"
}

# bk_run_task_tree: run an task and its dependencies (no circular deps).
# Usage: bk_run_task_tree <task>
bk_task_run_tree() {
  local task="$1"

  fn_debug "Running task: $task"

  # Skip non-task meta sections.
  fn_in_array "$task" "${IGNORE_SECTIONS[@]}" && {
    fn_error "This task is system protected:" "$task"
    ERR_SET["$task"]=1
  } && return 1

  if ! bk_task_validate_name "$task"; then
    fn_error "task name has invalid characters: $task"
    ERR_SET["$task"]=1
    return 1
  fi

  # Already done.
  [[ -n "${RUN_SET[$task]:-}" ]] && {
     fn_debug "The task already run: $task "
     return 0
  }

  # Detect circular dependency.
  if [[ -n "${WALK_SET[$task]:-}" ]]; then
    fn_error "Circular dependency detected at task: $task"
    ERR_SET["$task"]=1
    return 1
  fi

  WALK_SET["$task"]=1

  # Run dependencies first.
  local deps_raw deps dep
  deps_raw="$(bk_task_deps "$task")"
  fn_debug "Checking task dependencies: $deps_raw"
  if [[ -n "${deps_raw// }" ]]; then
    IFS=',' read -r -a deps <<<"${deps_raw}"
    for dep in "${deps[@]}"; do
      fn_debug "Task: $task: Running dependency: $dep ..."

      dep="$(fn_trim "$dep")"
      [[ -z "$dep" ]] && continue

      if [[ -n "${ERR_SET[$dep]:-}" ]]; then
        fn_error "task $task requires $dep, but $dep previously failed."
        ERR_SET["$task"]=1
        return 1
      fi

      bk_task_run_tree "$dep" || {
        fn_error "Dependency $dep failed; skipping $task."
        ERR_SET["$task"]=1
        return 1
      }
    done
  fi

  # Run the task itself.
  fn_info "Running task: $task"
  bk_task_run "$task"
}

bk_task_run() {
  local task="$1"

  CURRENT_TASK="$task"

  # load task config:
  bk_task_load_cfg "$task"

  # use a erorfile to be able to notify error:
  bk_mktemp_set 'cfg[ErrorFile]' "$task" "errfile" "file"

  bk_task_run_internal "$task" 2> >(tee "${cfg[ErrorFile]}" >&2)
  local ret=$?
  wait  # ensures tee finishes writing before reading the file

  if [[ $ret -eq 0 ]]; then
    RUN_SET["$task"]=1
    # success
    fn_success "$C_RESET" "Task " "$C_BOLD" "$task" "$C_RESET" " was successfull completed."
    fn_notify "$task" "success"
  else
    ERR_SET["$task"]=1
    fn_failed "$C_RESET" "Task " "$C_BOLD" "$task" "$C_RESET" " failed to complete."
    fn_notify "$task" "failed"
  fi
  CURRENT_TASK=
  return $ret
}

# bk_run_task: load an task config, validate it, and dispatch by Type.
# Usage: bk_run_task <task>
bk_task_run_internal() {
  local task="$1"

  if [[ ${#cfg[@]} -eq 0 ]]; then
    fn_error "Task [$task] not found in config."
    return 1
  fi
  # check skip
  if fn_boolean "${cfg[Skip]:-}"; then
    fn_debug "Skipping Task $task as configured.."
    return 0
  fi
  #check essential configurations:
  if [[ -z "${cfg[Type]:-}" ]] || [[ -z "${cfg[From]:-}" ]] || \
     [[ -z "${cfg[To]:-}" ]]; then
        fn_error "You need to set Type=, From=, and To= in the task configuration"
        return 1
  fi

  bk_hook_run "Before" || {
    fn_error "[$task] Before hook failed; aborting action."
    return 1
  }

  # dispatch to Type.
  local type="${cfg[Type]:-}"
  case "${type,,}" in
    backup)  bk_type_backup ;;
    local) bk_type_local ;;
    remote) bk_type_local ;;
    *)
      fn_error "[$task] Unknown Type: $type"
      return 1
      ;;
  esac
  local ret=$?
  if [[ "$ret" -ne 0 ]]; then
    fn_error "[$task] Type ${cfg[Type]:-} execution failed with code $ret"
    return "$ret"
  fi

  bk_hook_run "After" || {
    fn_error "[$task] After hook failed."
    return 1
  }

}

# bk_load_task_cfg: load [General] plus the requested task section into cfg.
# Usage: bk_load_task_cfg <task>
bk_task_load_cfg() {
  local task="$1"
  declare -gA cfg=()
  fn_ini_load_sections cfg "${BK_CONFIG}" "General,${task}"
  cfg[Name]="$task"
  # Expand ~ in From/To (common in configs).
  [[ "${cfg[From]:-}" == ~/* ]] && cfg[From]="${HOME}/${cfg[From]#~/}"
  [[ "${cfg[To]:-}" == ~/* ]] && cfg[To]="${HOME}/${cfg[To]#~/}"

  # Normalize paths for keys that are expected to be file paths.
  fn_normalize_cfg_paths cfg "IncludeFrom:ExcludeFrom:FilterFrom:EncryptKeyFile"
}
